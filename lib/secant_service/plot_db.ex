defmodule SecantService.PlotDB do
  @moduledoc """
  Plots of parameters and modules: what a plot draws (its lines), building
  it (`SecantService.PlotDB.TimePlot`, or `ArrayLatest` for long arrays) and
  turning later readings into updates of its series.
  """

  alias SecantService.SecNodes
  alias SecantService.Util
  alias SecantService.PlotDB.Builders
  alias SecantService.PlotDB.TimePlot
  alias SecantService.PlotDB.DTypes.ArrayHeatmap
  alias SecantService.PlotDB.DTypes.ArrayLatest
  alias SecantService.PlotDB.DTypes.Scalar
  alias SecantService.PlotDB.DTypes.Struct, as: StructDType

  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.Module
  alias SecantClient.NodeTable

  # ---------------------------------------------------------------------------
  # Lines of a plot, by interface class
  # ---------------------------------------------------------------------------

  @value %{name: "value", setpoint?: false, hidden?: false}
  @target %{name: "target", setpoint?: true, hidden?: false}

  @readable [@value]

  @class_lines %{
    readable: @readable,
    acquisition: @readable,
    acquisition_channel: @readable,
    acquisition_controller: @readable,
    drivable: [@value, @target],
    # the extra lines start hidden in the legend
    calibratable: [
      @value,
      @target,
      %{name: "_value_uncalibrated", setpoint?: false, hidden?: true},
      %{name: "_target_calibrated", setpoint?: true, hidden?: true}
    ]
  }

  @setpoints ~w(target _target_calibrated)

  @doc """
  The lines a plot of `secop_obj` draws, value first, as
  `%{param:, series:, setpoint?:, hidden?:}`. A parameter plotted on its own
  is the plot's `value` series; a module's lines are its parameters named by
  its interface class, as far as it has them. Empty when nothing is plotted.

  A setpoint (`target`, `_target_calibrated`) is only recorded when it
  changes, so its readings are held from before a window.
  """
  def lines(%Parameter{} = param) do
    [%{param: param, series: "value", setpoint?: param.name in @setpoints, hidden?: false}]
  end

  def lines(%Module{} = module) do
    iface_class = Util.get_highest_if_class(module.interface_classes)

    lines =
      for spec <- Map.get(@class_lines, iface_class, []),
          %Parameter{} = param <- [Builders.find_param(module, spec.name)],
          do: Map.merge(spec, %{param: param, series: spec.name}) |> Map.delete(:name)

    case {iface_class, lines} do
      # its calibration lines are numbers; anything else isn't plotted
      {:calibratable, [%{param: value} | _]} ->
        if Scalar.supported_type?(value.datainfo), do: lines, else: []

      {_class, [%{series: "value"} | _]} ->
        lines

      _no_value ->
        []
    end
  end

  @doc "The names of the parameters whose readings go into `secop_obj`'s plot."
  def param_list(secop_obj), do: secop_obj |> lines() |> Enum.map(& &1.param.name)

  # ---------------------------------------------------------------------------
  # Building
  # ---------------------------------------------------------------------------

  def init(secop_obj, mode \\ :live) do
    lines = lines(secop_obj)

    case long_array(lines) do
      {param, latest} -> ArrayLatest.plot(param, latest)
      nil -> build(lines, mode)
    end
  end

  def module_plot(%Module{} = module, mode \\ :live), do: module |> lines() |> build(mode)

  def parameter_plot(%Parameter{} = parameter, mode \\ :live) do
    if plottable?(parameter), do: parameter |> lines() |> build(mode), else: not_plottable()
  end

  defp build(lines, mode) do
    case TimePlot.build(lines, mode) do
      :not_plottable -> not_plottable()
      plot -> plot
    end
  end

  # Arrays longer than the heatmap can carry are plotted as their latest
  # reading only. Checked before any history is loaded: a few minutes of a
  # 350 000-element spectrum would be far too much to fetch.
  defp long_array([%{param: param} | _]) do
    with true <- ArrayLatest.numeric_array?(param),
         {arr, _ts} = latest <- ArrayLatest.fetch_latest(param),
         true <- length(arr) > TimePlot.max_array_len() do
      {param, latest}
    else
      _ -> nil
    end
  end

  defp long_array([]), do: nil

  @doc """
  When a reading of the parameter `name` makes a heatmap's array longer than
  it can carry (e.g. a spectrum that was 3 points at startup and 10 000
  after an acquisition), the batch's final array reading `{array, ms}`, to
  rebuild the plot as the latest-reading plot from. Otherwise nil.
  """
  def outgrown(%{plot_type: :array_heatmap, lines: lines}, name, datapoints) do
    # any long reading in the batch counts, not only the last one: it must
    # not go into the heatmap. The new plot starts from the batch's final
    # reading, long or not (the latest-reading plot shows short ones too).
    long? = fn {arr, _ts} -> is_list(arr) and length(arr) > TimePlot.max_array_len() end

    if Map.has_key?(lines, name) and Enum.any?(datapoints, long?) do
      datapoints |> Enum.filter(&is_list(elem(&1, 0))) |> List.last()
    end
  end

  def outgrown(_plot, _name, _datapoints), do: nil

  # ---------------------------------------------------------------------------
  # Plottability check
  # ---------------------------------------------------------------------------

  def plottable?(%Parameter{} = parameter) do
    case parameter.datainfo do
      %{"type" => numeric} when numeric in ["double", "int", "scaled", "enum"] ->
        true

      # short arrays as a time × index heatmap, long ones as their latest reading
      %{"type" => "array"} = datainfo ->
        ArrayHeatmap.supported_type?(datainfo)

      %{"type" => "struct"} = datainfo ->
        StructDType.supported_type?(datainfo)

      _ ->
        false
    end
  end

  def plottable?(%Module{} = module) do
    case Builders.find_param(module, "value") do
      nil -> false
      param -> plottable?(param)
    end
  end

  # ---------------------------------------------------------------------------
  # Updates
  # ---------------------------------------------------------------------------

  @doc """
  The chart update for readings of the parameter `name`: `%{seriesUpdates:
  [%{seriesIndex:, data:}]}`, with `arrayLen` for a heatmap. Empty for a
  parameter the plot doesn't draw.
  """
  def trace_updates(%{plot_type: :array_latest} = plot, datapoints, name),
    do: ArrayLatest.trace_updates(plot, datapoints, name)

  def trace_updates(%{lines: lines, option: option}, datapoints, name) do
    case Map.get(lines, name) do
      nil ->
        %{seriesUpdates: []}

      %{series: series, dtype: ArrayHeatmap} ->
        %{
          seriesUpdates: ArrayHeatmap.series_updates(option, datapoints, series),
          arrayLen: ArrayHeatmap.array_len_from_datapoints(datapoints)
        }

      %{series: series, dtype: dtype} ->
        %{seriesUpdates: dtype.series_updates(option, datapoints, series)}
    end
  end

  def trace_updates(_plot, _datapoints, _name), do: %{seriesUpdates: []}

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

  def not_plottable, do: %{plottable: false}

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
