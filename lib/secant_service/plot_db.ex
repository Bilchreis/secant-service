defmodule SecantService.PlotDB do
  alias SecantService.SecNodes
  alias SecantService.Util
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.DTypes.ArrayLatest
  alias SecantService.PlotDB.DTypes.Enum, as: EnumDType
  alias SecantService.PlotDB.DTypes.Scalar
  alias SecantService.PlotDB.DTypes.Struct, as: StructDType
  alias SecantService.PlotDB.History

  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.Module
  alias SecantClient.NodeTable

  @max_array_len 100

  # ---------------------------------------------------------------------------
  # Interface-class registry — atom → plot module
  # ---------------------------------------------------------------------------

  @class_registry %{
    readable: SecantService.PlotDB.Readable,
    drivable: SecantService.PlotDB.Drivable,
    calibratable: SecantService.PlotDB.Calibratable,
    acquisition: SecantService.PlotDB.Acquisition,
    acquisition_channel: SecantService.PlotDB.Acquisition,
    acquisition_controller: SecantService.PlotDB.Acquisition
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def init(secop_obj, mode \\ :live) do
    case long_array(secop_obj) do
      {param, latest} ->
        ArrayLatest.plot(param, latest)

      nil ->
        case secop_obj do
          %Parameter{} = param -> parameter_plot(param, mode)
          %Module{} = mod -> module_plot(mod, mode)
        end
        |> put_history_resolution(secop_obj)
    end
  end

  @doc """
  The parameters of a plot whose readings are thinned out in the database for
  the historical view (see `History`).
  """
  def history_params(secop_obj) do
    secop_obj
    |> param_list()
    |> Enum.map(&resolve_param(secop_obj, &1))
    |> Enum.filter(&History.thinnable?/1)
  end

  defp resolve_param(%Parameter{} = param, _name), do: param
  defp resolve_param(%Module{} = module, name), do: Builders.find_param(module, name)

  # Historical plots that load more detail on zoom start with thinned-out
  # readings when the recording is long: tell the chart, so it can say so.
  defp put_history_resolution(%{option: %{_windowFetch: _}} = plot, secop_obj) do
    resolution =
      secop_obj
      |> history_params()
      |> Enum.map(&SecNodes.history_resolution!(&1.id, Builders.plot_start_ms(&1), nil))
      |> History.coarsest()

    put_in(plot, [:option, :_windowFetch], resolution)
  end

  defp put_history_resolution(plot, _secop_obj), do: plot

  # Arrays longer than the heatmap can carry are plotted as their latest
  # reading only. Checked before any history is loaded: a few minutes of a
  # 350 000-element spectrum would be far too much to fetch.
  defp long_array(%Module{} = module) do
    case Builders.find_param(module, "value") do
      nil -> nil
      param -> long_array(param)
    end
  end

  defp long_array(%Parameter{} = param) do
    with true <- ArrayLatest.numeric_array?(param),
         {arr, _ts} = latest <- ArrayLatest.fetch_latest(param),
         true <- length(arr) > @max_array_len do
      {param, latest}
    else
      _ -> nil
    end
  end

  @doc """
  When a live reading makes the plotted array longer than the heatmap can
  carry (e.g. a spectrum that was 3 points at startup and 10 000 after an
  acquisition), returns `{param, {array, ms}}` to rebuild the plot as the
  latest-reading plot. Otherwise nil.
  """
  def outgrown(%{plot_type: :array_latest}, _secop_obj, _datapoints, _parameter), do: nil

  def outgrown(_plot_map, secop_obj, datapoints, parameter) do
    param =
      case secop_obj do
        %Module{} = module -> parameter == "value" && Builders.find_param(module, "value")
        %Parameter{name: ^parameter} = param -> param
        _ -> nil
      end

    # any long reading in the batch counts, not only the last one: it must
    # not go into the heatmap. The new plot starts from the batch's final
    # reading, long or not (the latest-reading plot shows short ones too).
    long? = fn {arr, _ts} -> is_list(arr) and length(arr) > @max_array_len end

    with %Parameter{} <- param,
         true <- ArrayLatest.numeric_array?(param),
         true <- Enum.any?(datapoints, long?) do
      {param, datapoints |> Enum.filter(&is_list(elem(&1, 0))) |> List.last()}
    else
      _ -> nil
    end
  end

  def module_plot(module, mode \\ :live) do
    case plot_module_for(module) do
      nil ->
        not_plottable()

      mod ->
        case mod.plot(module, mode) do
          {:ok, plot} -> plot
          :not_plottable -> not_plottable()
        end
    end
  end

  # Schema-specific plot modules aren't implemented yet. When the first one is
  # added, look up `get_in(module.custom_properties || %{}, ["schema"])` in a
  # schema registry first and fall back to the interface-class registry.
  defp plot_module_for(module) do
    iface_class = Util.get_highest_if_class(module.interface_classes)
    Map.get(@class_registry, iface_class)
  end

  def param_list(%Parameter{} = parameter), do: [parameter.name]

  def param_list(%Module{} = module) do
    case plot_module_for(module) do
      nil -> []
      mod -> mod.param_names()
    end
  end

  def parameter_plot(parameter, mode \\ :live) do
    if plottable?(parameter) do
      {val, ts} = Builders.fetch_param_data(parameter, mode)
      unit = get_in(parameter.datainfo, ["unit"])

      case parameter.datainfo["type"] do
        "array" ->
          array_len = ArrayHeatmap.max_len(val)

          # a long reading inside the window: plot the latest reading instead
          if array_len > @max_array_len do
            ArrayLatest.plot(parameter, ArrayLatest.fetch_latest(parameter))
          else
            option =
              ArrayHeatmap.heatmap_option(
                [ArrayHeatmap.heatmap_series(ts, val)],
                array_len,
                ArrayHeatmap.unit(parameter.datainfo),
                mode,
                name: parameter.name
              )

            %{
              plottable: true,
              plot_available: Builders.plot_available?(val, parameter, mode),
              plot_type: :array_heatmap,
              option: option
            }
          end

        "enum" ->
          members = parameter.datainfo["members"]
          series = [EnumDType.enum_series("value", ts, val, members)]
          option = EnumDType.enum_timeseries_option(series, members, "value", mode)

          %{
            plottable: true,
            plot_available: Builders.plot_available?(val, parameter, mode),
            option: option
          }

        "struct" ->
          option = StructDType.build_struct_option("value", ts, val, parameter.datainfo, mode)
          dtype_mod = DTypePlot.for_datainfo(parameter.datainfo)

          %{
            plottable: true,
            plot_available: Builders.plot_available?(val, parameter, mode),
            option: option,
            _param_dtype_modules: %{"value" => dtype_mod}
          }

        _ ->
          series = [Scalar.scalar_line_series("value", ts, val)]
          option = Scalar.timeseries_option(series, unit, mode)

          %{
            plottable: true,
            plot_available: Builders.plot_available?(val, parameter, mode),
            option: option
          }
      end
    else
      not_plottable()
    end
  end

  # ---------------------------------------------------------------------------
  # Plottability check
  # ---------------------------------------------------------------------------

  def plottable?(%Parameter{} = parameter) do
    case parameter.datainfo do
      %{"type" => numeric} when numeric in ["double", "int", "scaled", "enum"] ->
        true

      # short arrays as a time × index heatmap, long ones as their latest reading
      %{"type" => "array", "members" => %{"type" => member_type}}
      when member_type in ["double", "int", "scaled"] ->
        true

      %{"type" => "struct"} = datainfo ->
        StructDType.supported_type?(datainfo)

      _ ->
        false
    end
  end

  def plottable?(%Module{} = module) do
    value_param = Enum.find(module.parameters, fn p -> p.name == "value" end)

    case value_param do
      nil -> false
      param -> plottable?(param)
    end
  end

  # ---------------------------------------------------------------------------
  # Live update formatting
  # ---------------------------------------------------------------------------

  def get_trace_updates_batch(%{plot_type: :array_latest} = plot_map, datapoints, parameter) do
    ArrayLatest.trace_updates(plot_map, datapoints, parameter)
  end

  # Module plots (from PlotSpec implementations) carry _plot_spec_module for clean dispatch.
  def get_trace_updates_batch(%{_plot_spec_module: mod} = plot_map, datapoints, parameter) do
    mod.trace_updates(plot_map, datapoints, parameter)
  end

  # Parameter plots and any legacy plot_maps fall back to the original inline dispatch.
  def get_trace_updates_batch(%{plot_type: :array_heatmap} = _plot_map, datapoints, _parameter) do
    data =
      Enum.flat_map(datapoints, fn {arr, ts} ->
        arr |> Enum.with_index() |> Enum.map(fn {v, i} -> [ts, i, v] end)
      end)

    array_len = ArrayHeatmap.array_len_from_datapoints(datapoints)

    %{seriesUpdates: [%{seriesIndex: 0, data: data}], arrayLen: array_len}
  end

  def get_trace_updates_batch(
        %{_param_dtype_modules: mods, option: opt} = _plot_map,
        datapoints,
        parameter
      ) do
    dtype_mod = Map.get(mods, parameter)
    series_upds = dtype_mod.series_updates(opt, datapoints, parameter)
    result = %{seriesUpdates: series_upds}

    if dtype_mod == ArrayHeatmap do
      Map.put(result, :arrayLen, ArrayHeatmap.array_len_from_datapoints(datapoints))
    else
      result
    end
  end

  def get_trace_updates_batch(plot_map, datapoints, parameter) do
    series_index =
      Enum.find_index(plot_map.option.series, fn s -> s.name == parameter end) || 0

    {values, timestamps} = Enum.unzip(datapoints)

    data =
      case Map.get(plot_map.option, :_enumMembers) do
        nil ->
          Enum.zip(timestamps, values) |> Enum.map(&Tuple.to_list/1)

        int_to_info ->
          y_val =
            case Map.get(plot_map.option, :_enumSeriesY) do
              nil -> 0
              series_y -> Map.get(series_y, parameter, 0)
            end

          Enum.zip_with(timestamps, values, fn ts, v ->
            %{name: name, color: color} =
              Map.get(int_to_info, to_string(v), %{name: to_string(v), color: "#888888"})

            %{value: [ts, y_val], name: "#{name} (#{v})", itemStyle: %{color: color}}
          end)
      end

    %{seriesUpdates: [%{seriesIndex: series_index, data: data}]}
  end

  # ---------------------------------------------------------------------------
  # Calibration plot (standalone — uses NodeTable directly, not DB values)
  # ---------------------------------------------------------------------------

  def calibration_plot(%Module{} = module) do
    %{sec_node: %{node_id: node_id}} = SecNodes.get_module!(module.id)

    module_atom = String.to_existing_atom(module.name)

    fwd_coeffs =
      lookup_calib_coeff(node_id, module_atom, [
        "_forward_calib_coeff",
        "_forward_calibration_coefficients"
      ])

    inv_coeffs =
      lookup_calib_coeff(node_id, module_atom, [
        "_inverse_calib_coeff",
        "_inverse_calibration_coefficients"
      ])

    case {fwd_coeffs, inv_coeffs} do
      {nil, _} ->
        not_plottable()

      {_, nil} ->
        not_plottable()

      {fwd, inv} ->
        value_param = Enum.find(module.parameters, fn p -> p.name == "value" end)
        {x_min, x_max} = get_calib_range(node_id, module)

        n = 100
        step = (x_max - x_min) / (n - 1)
        setpoints = Enum.map(0..(n - 1), fn i -> x_min + step * i end)

        hw_values = Enum.map(setpoints, fn sp -> polyval(fwd, sp) end)
        calib_readback = Enum.map(hw_values, fn hw -> polyval(inv, hw) end)
        roundtrip_err = Enum.zip_with(calib_readback, setpoints, fn rb, sp -> rb - sp end)

        unit = Map.get(value_param.datainfo || %{}, "unit", "")
        unit_label = if unit != "", do: " (#{unit})", else: ""

        identity_line = Enum.zip_with(setpoints, setpoints, &[&1, &2])

        identity_series_style = %{
          type: "line",
          symbol: "none",
          lineStyle: %{color: "gray", type: "dashed", opacity: 0.5},
          silent: true
        }

        series = [
          %{
            name: "hardware value",
            type: "line",
            symbol: "none",
            xAxisIndex: 0,
            yAxisIndex: 0,
            data: Enum.zip_with(setpoints, hw_values, &[&1, &2]),
            lineStyle: %{color: "steelblue"}
          },
          Map.merge(identity_series_style, %{
            name: "identity_fwd",
            xAxisIndex: 0,
            yAxisIndex: 0,
            data: identity_line
          }),
          %{
            name: "calibrated readback",
            type: "line",
            symbol: "none",
            xAxisIndex: 1,
            yAxisIndex: 1,
            data: Enum.zip_with(hw_values, calib_readback, &[&1, &2]),
            lineStyle: %{color: "crimson"}
          },
          Map.merge(identity_series_style, %{
            name: "identity_inv",
            xAxisIndex: 1,
            yAxisIndex: 1,
            data: Enum.zip_with(hw_values, hw_values, &[&1, &2])
          }),
          %{
            name: "roundtrip result",
            type: "line",
            symbol: "none",
            xAxisIndex: 2,
            yAxisIndex: 2,
            data: Enum.zip_with(setpoints, calib_readback, &[&1, &2]),
            lineStyle: %{color: "seagreen"}
          },
          Map.merge(identity_series_style, %{
            name: "identity_rt",
            xAxisIndex: 2,
            yAxisIndex: 2,
            data: identity_line
          }),
          %{
            name: "roundtrip error",
            type: "line",
            symbol: "none",
            xAxisIndex: 3,
            yAxisIndex: 3,
            data: Enum.zip_with(setpoints, roundtrip_err, &[&1, &2]),
            lineStyle: %{color: "mediumpurple"}
          }
        ]

        option = %{
          backgroundColor: "transparent",
          grid: [
            %{left: "5%", top: "8%", width: "42%", height: "38%", containLabel: true},
            %{left: "55%", top: "8%", width: "42%", height: "38%", containLabel: true},
            %{left: "5%", top: "58%", width: "42%", height: "34%", containLabel: true},
            %{left: "55%", top: "58%", width: "42%", height: "34%", containLabel: true}
          ],
          xAxis: [
            %{
              gridIndex: 0,
              type: "value",
              name: "Setpoint#{unit_label}",
              nameLocation: "middle",
              nameGap: 25
            },
            %{
              gridIndex: 1,
              type: "value",
              name: "Raw hardware value#{unit_label}",
              nameLocation: "middle",
              nameGap: 25
            },
            %{
              gridIndex: 2,
              type: "value",
              name: "Setpoint#{unit_label}",
              nameLocation: "middle",
              nameGap: 25
            },
            %{
              gridIndex: 3,
              type: "value",
              name: "Setpoint#{unit_label}",
              nameLocation: "middle",
              nameGap: 25
            }
          ],
          yAxis: [
            %{
              gridIndex: 0,
              type: "value",
              name: "Hardware value#{unit_label}",
              nameLocation: "middle",
              nameRotate: 90,
              nameGap: 50
            },
            %{
              gridIndex: 1,
              type: "value",
              name: "Calibrated readback#{unit_label}",
              nameLocation: "middle",
              nameRotate: 90,
              nameGap: 50
            },
            %{
              gridIndex: 2,
              type: "value",
              name: "Calibrated readback#{unit_label}",
              nameLocation: "middle",
              nameRotate: 90,
              nameGap: 50
            },
            %{
              gridIndex: 3,
              type: "value",
              name: "Error#{unit_label}",
              nameLocation: "middle",
              nameRotate: 90,
              nameGap: 50
            }
          ],
          title: [
            %{
              text: "Forward Calibration: Setpoint → Hardware",
              left: "26%",
              top: "1%",
              textAlign: "center",
              textStyle: %{fontSize: 12}
            },
            %{
              text: "Inverse Calibration: Hardware → Readback",
              left: "76%",
              top: "1%",
              textAlign: "center",
              textStyle: %{fontSize: 12}
            },
            %{
              text: "Roundtrip: Setpoint → Forward → Inverse",
              left: "26%",
              top: "51%",
              textAlign: "center",
              textStyle: %{fontSize: 12}
            },
            %{
              text: "Roundtrip Error",
              left: "76%",
              top: "51%",
              textAlign: "center",
              textStyle: %{fontSize: 12}
            }
          ],
          legend: %{show: false},
          series: series
        }

        %{
          plottable: true,
          plot_available: true,
          option: option,
          fwd_coeffs: fwd,
          inv_coeffs: inv
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Sentinel values
  # ---------------------------------------------------------------------------

  def no_plot_available, do: %{plottable: true, plot_available: false}

  def not_plottable, do: %{plottable: false, plot_available: false, topics: []}

  # ---------------------------------------------------------------------------
  # Calibration helpers (private)
  # ---------------------------------------------------------------------------

  # Tries each parameter name in order (new short name first, old long name as
  # fallback) so both the pre- and post-rename Calibratable interface classes work.
  defp lookup_calib_coeff(node_id, module_atom, names) do
    Enum.find_value(names, fn name ->
      try do
        case NodeTable.lookup(
               {:service, node_id},
               {:data_report, module_atom, String.to_existing_atom(name)}
             ) do
          {:ok, %{data_report: [value, _]}} -> value
          # an error report, or nothing received yet
          _ -> nil
        end
      rescue
        ArgumentError -> nil
      end
    end)
  end

  defp polyval(coeffs, x) do
    coeffs
    |> Enum.with_index()
    |> Enum.reduce(0.0, fn {c, i}, acc -> acc + c * :math.pow(x, i) end)
  end

  defp get_calib_range(node_id, module) do
    module_atom = String.to_existing_atom(module.name)

    lookup_param_value = fn param_name ->
      case NodeTable.lookup(
             {:service, node_id},
             {:data_report, module_atom, String.to_existing_atom(param_name)}
           ) do
        {:ok, %{data_report: [value, _]}} -> value
        _ -> nil
      end
    end

    case lookup_param_value.("target_limits") do
      [min, max] when is_number(min) and is_number(max) and min < max ->
        {min * 1.0, max * 1.0}

      _ ->
        target_param = Enum.find(module.parameters, fn p -> p.name == "target" end)
        target_datainfo = if target_param, do: target_param.datainfo || %{}, else: %{}

        target_min_val = lookup_param_value.("target_min")
        target_max_val = lookup_param_value.("target_max")

        datainfo_min = Map.get(target_datainfo, "min")
        datainfo_max = Map.get(target_datainfo, "max")

        resolved_min =
          cond do
            is_number(target_min_val) -> target_min_val * 1.0
            is_number(target_max_val) and is_number(datainfo_min) -> datainfo_min * 1.0
            is_number(datainfo_min) -> datainfo_min * 1.0
            true -> nil
          end

        resolved_max =
          cond do
            is_number(target_max_val) -> target_max_val * 1.0
            is_number(target_min_val) and is_number(datainfo_max) -> datainfo_max * 1.0
            is_number(datainfo_max) -> datainfo_max * 1.0
            true -> nil
          end

        case {resolved_min, resolved_max} do
          {min, max} when is_number(min) and is_number(max) and min < max ->
            {min, max}

          _ ->
            value_param = Enum.find(module.parameters, fn p -> p.name == "value" end)
            value_datainfo = if value_param, do: value_param.datainfo || %{}, else: %{}
            val_min = Map.get(value_datainfo, "min")
            val_max = Map.get(value_datainfo, "max")

            if is_number(val_min) and is_number(val_max) and val_min < val_max do
              {val_min * 1.0, val_max * 1.0}
            else
              {-50.0, 50.0}
            end
        end
    end
  end
end
