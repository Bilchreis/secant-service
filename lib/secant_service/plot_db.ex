defmodule SecantService.PlotDB do
  alias SecantService.Util
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.DTypePlot
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.DTypes.Enum, as: EnumDType
  alias SecantService.PlotDB.DTypes.Scalar
  alias SecantService.PlotDB.DTypes.Struct, as: StructDType

  alias SecantService.SecNodes.ParameterValue
  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.Module
  alias NodeTable

  @max_array_len 100

  # ---------------------------------------------------------------------------
  # Interface-class registry — atom → plot module
  # ---------------------------------------------------------------------------

  @class_registry %{
    readable: SecantService.PlotDB.Readable,
    drivable: SecantService.PlotDB.Drivable,
    calibratable: SecantService.PlotDB.Calibratable,
    acquisition: SecantService.PlotDB.Acquisition
  }

  # ---------------------------------------------------------------------------
  # Schema registry — add one clause per schema-specific plot module.
  # The type checker will warn that the catch-all always returns nil until a
  # real clause is added; that warning is intentional and will disappear then.
  #
  # Example:
  #   defp schema_plot_module("https://example.org/schemas/HeliumLevel@v1.0"),
  #     do: SecantService.PlotDB.Schemas.HeliumLevel
  # ---------------------------------------------------------------------------

  defp schema_plot_module(_schema_id), do: nil

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def init(secop_obj, mode \\ :live) do
    case secop_obj do
      %Parameter{} = param -> parameter_plot(param, mode)
      %Module{} = mod -> module_plot(mod, mode)
    end
  end

  def module_plot(module, mode \\ :live) do
    schema_id = get_in(module.custom_properties || %{}, ["schema"])
    iface_class = Util.get_highest_if_class(module.interface_classes)

    plot_module =
      case schema_plot_module(schema_id) do
        nil -> Map.get(@class_registry, iface_class)
        mod -> mod
      end

    case plot_module do
      nil ->
        not_plottable()

      mod ->
        case mod.plot(module, mode) do
          {:ok, plot} -> plot
          :not_plottable -> not_plottable()
        end
    end
  end

  def param_list(%Parameter{} = parameter), do: [parameter.name]

  def param_list(%Module{} = module) do
    schema_id = get_in(module.custom_properties || %{}, ["schema"])
    iface_class = Util.get_highest_if_class(module.interface_classes)

    plot_module =
      case schema_plot_module(schema_id) do
        nil -> Map.get(@class_registry, iface_class)
        mod -> mod
      end

    case plot_module do
      nil -> []
      mod -> mod.param_names()
    end
  end

  def parameter_plot(parameter, mode \\ :live) do
    if plottable?(parameter) do
      {val, ts} = Builders.fetch_param_data(parameter)
      unit = get_in(parameter.datainfo, ["unit"])

      case parameter.datainfo["type"] do
        "array" ->
          array_len = val |> List.first([]) |> length()

          if array_len > @max_array_len do
            not_plottable()
          else
            option =
              ArrayHeatmap.heatmap_option(
                [ArrayHeatmap.heatmap_series(ts, val)],
                array_len,
                unit,
                mode
              )

            %{
              plottable: true,
              plot_available: length(val) > 1,
              plot_type: :array_heatmap,
              option: option
            }
          end

        "enum" ->
          members = parameter.datainfo["members"]
          series = [EnumDType.enum_series("value", ts, val, members)]
          option = EnumDType.enum_timeseries_option(series, members, "value", mode)
          %{plottable: true, plot_available: length(val) > 1, option: option}

        "struct" ->
          option = StructDType.build_struct_option("value", ts, val, parameter.datainfo, mode)
          dtype_mod = DTypePlot.for_datainfo(parameter.datainfo)

          %{
            plottable: true,
            plot_available: length(val) > 1,
            option: option,
            _param_dtype_modules: %{"value" => dtype_mod}
          }

        _ ->
          series = [Scalar.scalar_line_series("value", ts, val)]
          option = Scalar.timeseries_option(series, unit, mode)
          %{plottable: true, plot_available: length(val) > 1, option: option}
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

      %{"type" => "array", "members" => %{"type" => member_type}}
      when member_type in ["double", "int", "scaled"] ->
        latest =
          ParameterValue.get_resource_module(parameter)
          |> Ash.Query.for_read(:for_parameter, %{
            parameter_id: parameter.id,
            limit: 1,
            order: :desc
          })
          |> Ash.read_first()

        case latest do
          {:ok, nil} -> true
          {:ok, record} when is_list(record.value) -> length(record.value) <= @max_array_len
          {:ok, _} -> true
          {:error, _} -> true
        end

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

  def get_trace_updates_batch(%{_param_dtype_modules: mods, option: opt} = _plot_map, datapoints, parameter) do
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
    %{sec_node: %{node_id: node_id}} =
      Module
      |> Ash.Query.for_read(:get_node_id, %{id: module.id})
      |> Ash.read_first!()

    fwd_coeffs =
      case NodeTable.lookup(
             {:service, node_id},
             {:data_report, String.to_existing_atom(module.name),
              String.to_existing_atom("_forward_calibration_coefficients")}
           ) do
        {:ok, %{data_report: [value, _]}} -> value
        {:error, _} -> nil
      end

    inv_coeffs =
      case NodeTable.lookup(
             {:service, node_id},
             {:data_report, String.to_existing_atom(module.name),
              String.to_existing_atom("_inverse_calibration_coefficients")}
           ) do
        {:ok, %{data_report: [value, _]}} -> value
        {:error, _} -> nil
      end

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
            %{gridIndex: 0, type: "value", name: "Setpoint#{unit_label}", nameLocation: "middle", nameGap: 25},
            %{gridIndex: 1, type: "value", name: "Raw hardware value#{unit_label}", nameLocation: "middle", nameGap: 25},
            %{gridIndex: 2, type: "value", name: "Setpoint#{unit_label}", nameLocation: "middle", nameGap: 25},
            %{gridIndex: 3, type: "value", name: "Setpoint#{unit_label}", nameLocation: "middle", nameGap: 25}
          ],
          yAxis: [
            %{gridIndex: 0, type: "value", name: "Hardware value#{unit_label}", nameLocation: "middle", nameRotate: 90, nameGap: 50},
            %{gridIndex: 1, type: "value", name: "Calibrated readback#{unit_label}", nameLocation: "middle", nameRotate: 90, nameGap: 50},
            %{gridIndex: 2, type: "value", name: "Calibrated readback#{unit_label}", nameLocation: "middle", nameRotate: 90, nameGap: 50},
            %{gridIndex: 3, type: "value", name: "Error#{unit_label}", nameLocation: "middle", nameRotate: 90, nameGap: 50}
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
        {:error, _} -> nil
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
