defmodule SecantService.PlotDB do
  alias SecantService.Util

  alias SEC_Node_Statem

  alias SecantService.SecNodes.ParameterValue
  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.Module
  alias NodeTable
  require Logger

  @markersize 5
  @max_array_len 100

  defp read_from_device_if_empty({_value_val, _value_ts} = readings, param_id) do
    case readings do
      {[], []} ->
        Logger.warning(
          "No values found in DB for param_id: #{param_id}, trying to read from device"
        )

        parameter =
          Parameter
          |> Ash.Query.for_read(:get_with_context, %{id: param_id})
          |> Ash.read_first!()

        # Retry indefinitely until we get a valid reading
        read_until_valid(
          parameter.module.sec_node.node_id,
          parameter.module.name,
          parameter.name
        )

      {_, _} ->
        readings
    end
  end

  defp read_until_valid(id, module_name, parameter_name) do
    case SEC_Node_Statem.read(id, module_name, parameter_name) do
      {:reply, _r_mod, _r_para, [val, %{t: ts}]} ->
        val = val |> Jason.encode!() |> Jason.decode!()

        # Convert Unix timestamp to DateTime
        secs = trunc(ts)
        usecs = trunc((ts - secs) * 1_000_000)
        {:ok, dt} = DateTime.from_unix(secs)
        ts = %{dt | microsecond: {usecs, 6}} |> DateTime.to_unix(:millisecond)

        {[val], [ts]}

      {:error, :read, _specifier, _error_class, error_text, _error_dict} ->
        Logger.warning("Read failed: #{error_text}, retrying...")
        # Add a small delay to avoid overwhelming the device
        Process.sleep(10000)
        read_until_valid(id, module_name, parameter_name)

      other ->
        Logger.warning("Unexpected response: #{inspect(other)}, retrying...")
        # Add a small delay to avoid overwhelming the device
        Process.sleep(20000)
        read_until_valid(id, module_name, parameter_name)
    end
  end

  defp get_values(parameter) do
    ParameterValue.get_resource_module(parameter)
    |> Ash.Query.for_read(:for_parameter, %{parameter_id: parameter.id})
    |> Ash.read!()
  end

  def get_layout(%{mode: :historical} = plot_map) do
    option = %{
      backgroundColor: "transparent",
      legend: %{orient: "vertical", right: 0, top: "center"},
      grid: %{top: 10, bottom: 40, left: 60, right: 80},
      xAxis: %{type: "time"},
      yAxis: %{type: "value", name: plot_map.unit || ""},
      series: []
    }

    Map.put(plot_map, :option, option)
  end

  def get_layout(plot_map) do
    buttons = [
      %{label: "1m", step: "minute", count: 1},
      %{label: "10m", step: "minute", count: 10},
      %{label: "30m", step: "minute", count: 30},
      %{label: "1h", step: "hour", count: 1},
      %{label: "1d", step: "day", count: 1},
      %{label: "all", step: "all"}
    ]

    active_button_index = 1
    now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    {x_min, x_max} = compute_range(Enum.at(buttons, active_button_index), now_ms)

    option = %{
      backgroundColor: "transparent",
      legend: %{orient: "vertical", right: 0, top: "center"},
      grid: %{top: 10, bottom: 40, left: 60, right: 80},
      xAxis: %{type: "time", min: x_min, max: x_max},
      yAxis: %{type: "value", name: plot_map.unit || ""},
      series: [],
      _rangeButtons: buttons,
      _activeButton: active_button_index
    }

    Map.put(plot_map, :option, option)
  end

  defp compute_range(%{step: "all"}, _now_ms), do: {nil, nil}

  defp compute_range(%{step: step, count: count}, now_ms) do
    ms =
      case step do
        "minute" -> count * 60 * 1_000
        "hour" -> count * 3_600 * 1_000
        "day" -> count * 86_400 * 1_000
        _ -> 0
      end

    {now_ms - ms, now_ms}
  end

  # single parameter/readable with scalar data
  def get_data(plot_map, value_ts, value_val) do
    series = [
      %{
        name: "value",
        type: "line",
        data: Enum.zip_with(value_ts, value_val, &[&1, &2]),
        symbol: "circle",
        symbolSize: @markersize,
        large: true,
        largeThreshold: 2000
      }
    ]

    Map.put(plot_map, :series, series)
  end

  # drivable with scalar data
  def get_data(plot_map, value_ts, value_val, target_ts, target_val) do
    series = [
      %{
        name: "value",
        type: "line",
        data: Enum.zip_with(value_ts, value_val, &[&1, &2]),
        symbol: "circle",
        symbolSize: @markersize,
        large: true,
        largeThreshold: 2000
      },
      %{
        name: "target",
        type: "line",
        data: Enum.zip_with(target_ts, target_val, &[&1, &2]),
        symbol: "circle",
        symbolSize: @markersize,
        large: true,
        largeThreshold: 2000
      }
    ]

    Map.put(plot_map, :series, series)
  end

  # calibratable with scalar data
  def get_data(
        plot_map,
        value_ts,
        value_val,
        value_uncalibrated_ts,
        value_uncalibrated_val,
        target_ts,
        target_val,
        target_calibrated_ts,
        target_calibrated_val
      ) do
    series = [
      %{
        name: "value",
        type: "line",
        data: Enum.zip_with(value_ts, value_val, &[&1, &2]),
        symbol: "circle",
        symbolSize: @markersize,
        large: true,
        largeThreshold: 2000
      },
      %{
        name: "target",
        type: "line",
        data: Enum.zip_with(target_ts, target_val, &[&1, &2]),
        symbol: "circle",
        symbolSize: @markersize,
        large: true,
        largeThreshold: 2000
      },
      %{
        name: "_value_uncalibrated",
        type: "line",
        data: Enum.zip_with(value_uncalibrated_ts, value_uncalibrated_val, &[&1, &2]),
        symbol: "circle",
        symbolSize: @markersize,
        large: true,
        largeThreshold: 2000
      },
      %{
        name: "_target_calibrated",
        type: "line",
        data: Enum.zip_with(target_calibrated_ts, target_calibrated_val, &[&1, &2]),
        symbol: "circle",
        symbolSize: @markersize,
        large: true,
        largeThreshold: 2000
      }
    ]

    Map.put(plot_map, :series, series)
  end

  defp get_data_array(plot_map, value_ts, value_val, parameter) do
    data =
      Enum.flat_map(Enum.zip(value_ts, value_val), fn {ts, arr} ->
        arr |> Enum.with_index() |> Enum.map(fn {v, i} -> [ts, i, v] end)
      end)

    array_len = value_val |> List.first([]) |> length()

    series = [
      %{
        type: "scatter",
        data: data,
        symbol: "rect",
        symbolSize: 8,
        encode: %{x: 0, y: 1},
        progressive: 0
      }
    ]

    plot_map
    |> Map.put(:series, series)
    |> Map.put(:array_len, array_len)
    |> Map.put(:plot_type, :array_heatmap)
  end

  defp get_layout_array(%{array_len: array_len, mode: mode} = plot_map) do
    y_max = max(array_len - 1, 0)

    color_scale = [
      "#313695",
      "#4575b4",
      "#74add1",
      "#abd9e9",
      "#e0f3f8",
      "#ffffbf",
      "#fee090",
      "#fdae61",
      "#f46d43",
      "#d73027",
      "#a50026"
    ]

    visual_map = %{
      calculable: true,
      orient: "vertical",
      right: 0,
      top: "center",
      dimension: 2,
      inRange: %{color: color_scale}
    }

    base_option = %{
      animation: false,
      backgroundColor: "transparent",
      grid: %{top: 10, bottom: 40, left: 60, right: 100},
      xAxis: %{type: "time"},
      yAxis: %{type: "value", min: 0, max: y_max, minInterval: 1},
      visualMap: visual_map,
      series: []
    }

    option =
      if mode == :historical do
        base_option
      else
        buttons = [
          %{label: "1m", step: "minute", count: 1},
          %{label: "10m", step: "minute", count: 10},
          %{label: "30m", step: "minute", count: 30},
          %{label: "1h", step: "hour", count: 1},
          %{label: "1d", step: "day", count: 1},
          %{label: "all", step: "all"}
        ]

        active_button_index = 1
        now_ms = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
        {x_min, x_max} = compute_range(Enum.at(buttons, active_button_index), now_ms)

        base_option
        |> Map.put(:xAxis, %{type: "time", min: x_min, max: x_max})
        |> Map.put(:_rangeButtons, buttons)
        |> Map.put(:_activeButton, active_button_index)
        |> Map.put(:_arrayLen, array_len)
      end

    Map.put(plot_map, :option, option)
  end

  def get_trace_updates_batch(%{plot_type: :array_heatmap} = _plot_map, datapoints, _parameter) do
    data =
      Enum.flat_map(datapoints, fn {arr, ts} ->
        arr |> Enum.with_index() |> Enum.map(fn {v, i} -> [ts, i, v] end)
      end)

    array_len =
      case List.first(datapoints) do
        {arr, _ts} -> length(arr)
        _ -> 0
      end

    %{seriesUpdates: [%{seriesIndex: 0, data: data}], arrayLen: array_len}
  end

  def get_trace_updates_batch(plot_map, datapoints, parameter) do
    series_index =
      Enum.find_index(plot_map.option.series, fn s -> s.name == parameter end) || 0

    {values, timestamps} = Enum.unzip(datapoints)
    data = Enum.zip(timestamps, values) |> Enum.map(&Tuple.to_list/1)

    %{seriesUpdates: [%{seriesIndex: series_index, data: data}]}
  end

  def plottable?(%SecantService.SecNodes.Parameter{} = parameter) do
    case parameter.datainfo do
      %{"type" => numeric} when numeric in ["double", "int", "scaled"] ->
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

      _ ->
        false
    end
  end

  def plottable?(%SecantService.SecNodes.Module{} = module) do
    value_param = Enum.find(module.parameters, fn param -> param.name == "value" end)

    case value_param do
      nil -> false
      param -> plottable?(param)
    end
  end

  def get_parameter(secop_obj) do
    case secop_obj do
      %SecantService.SecNodes.Parameter{} = param ->
        param

      %SecantService.SecNodes.Module{} = module ->
        Enum.find(module.parameters, fn param -> param.name == "value" end)
    end
  end

  defp get_unit(plot_map, parameter) do
    unit =
      if Map.has_key?(parameter.datainfo, "unit") do
        parameter.datainfo["unit"]
      else
        nil
      end

    Map.put(plot_map, :unit, unit)
  end

  defp plot_available(plot_map, plot_data) do
    plot_available =
      if length(plot_data) > 1 do
        true
      else
        false
      end

    Map.put(plot_map, :plot_available, plot_available)
  end

  defp set_chart_id(plot_map, chart_id) do
    Map.put(plot_map, :chart_id, chart_id)
  end

  defp finalize(%{option: option, series: series} = pm) do
    Map.put(pm, :option, Map.put(option, :series, series))
    |> Map.delete(:series)
  end

  defp finalize(pm), do: pm

  defp hide_calibratable_legend_series(%{option: option} = pm) do
    updated_option =
      Map.update(option, :legend, %{}, fn legend ->
        Map.put(legend, :selected, %{
          "_value_uncalibrated" => false,
          "_target_calibrated" => false
        })
      end)

    Map.put(pm, :option, updated_option)
  end

  def module_plot(module, mode \\ :live) do
    module_plot(module, Util.get_highest_if_class(module.interface_classes), mode)
  end

  def module_plot(module, :readable, mode) do
    plot_map = %{mode: mode}

    value_param = Enum.find(module.parameters, fn param -> param.name == "value" end)

    if plottable?(value_param) do
      plot_map =
        Map.put(plot_map, :plottable, true)
        |> get_unit(value_param)

      {value_val, value_ts} =
        get_values(value_param)
        |> ParameterValue.extract_value_timestamp_lists(value_param)
        |> read_from_device_if_empty(value_param.id)

      base = plot_map |> plot_available(value_val)

      case value_param.datainfo["type"] do
        "array" ->
          if value_val |> List.first([]) |> length() > @max_array_len do
            not_plottable()
          else
            base |> get_data_array(value_ts, value_val, value_param) |> get_layout_array() |> finalize()
          end

        _ ->
          base |> get_data(value_ts, value_val) |> get_layout() |> finalize()
      end
    else
      not_plottable()
    end
  end

  def module_plot(module, :drivable, mode) do
    plot_map = %{mode: mode}

    value_param = Enum.find(module.parameters, fn param -> param.name == "value" end)
    target_param = Enum.find(module.parameters, fn param -> param.name == "target" end)

    if plottable?(value_param) do
      plot_map =
        Map.put(plot_map, :plottable, true)
        |> get_unit(value_param)

      {value_val, value_ts} =
        get_values(value_param)
        |> ParameterValue.extract_value_timestamp_lists(value_param)
        |> read_from_device_if_empty(value_param.id)

      base = plot_map |> plot_available(value_val)

      case value_param.datainfo["type"] do
        "array" ->
          if value_val |> List.first([]) |> length() > @max_array_len do
            not_plottable()
          else
            base |> get_data_array(value_ts, value_val, value_param) |> get_layout_array() |> finalize()
          end

        _ ->
          {target_val, target_ts} =
            get_values(target_param)
            |> ParameterValue.extract_value_timestamp_lists(target_param)
            |> read_from_device_if_empty(target_param.id)

          base |> get_data(value_ts, value_val, target_ts, target_val) |> get_layout() |> finalize()
      end
    else
      not_plottable()
    end
  end

  def module_plot(module, :calibratable, mode) do
    plot_map = %{mode: mode}

    value_param = Enum.find(module.parameters, fn param -> param.name == "value" end)
    target_param = Enum.find(module.parameters, fn param -> param.name == "target" end)

    value_uncalibrated_param =
      Enum.find(module.parameters, fn param -> param.name == "_value_uncalibrated" end)

    target_calibrated_param =
      Enum.find(module.parameters, fn param -> param.name == "_target_calibrated" end)

    if plottable?(value_param) do
      plot_map =
        Map.put(plot_map, :plottable, true)
        |> get_unit(value_param)

      {value_val, value_ts} =
        get_values(value_param)
        |> ParameterValue.extract_value_timestamp_lists(value_param)
        |> read_from_device_if_empty(value_param.id)

      {target_val, target_ts} =
        get_values(target_param)
        |> ParameterValue.extract_value_timestamp_lists(target_param)
        |> read_from_device_if_empty(target_param.id)

      {value_uncalibrated_val, value_uncalibrated_ts} =
        get_values(value_uncalibrated_param)
        |> ParameterValue.extract_value_timestamp_lists(value_uncalibrated_param)
        |> read_from_device_if_empty(value_uncalibrated_param.id)

      {target_calibrated_val, target_calibrated_ts} =
        get_values(target_calibrated_param)
        |> ParameterValue.extract_value_timestamp_lists(target_calibrated_param)
        |> read_from_device_if_empty(target_calibrated_param.id)

      plot_map
      |> plot_available(value_val)
      |> get_data(
        value_ts,
        value_val,
        value_uncalibrated_ts,
        value_uncalibrated_val,
        target_ts,
        target_val,
        target_calibrated_ts,
        target_calibrated_val
      )
      |> get_layout()
      |> hide_calibratable_legend_series()
      |> finalize()
    else
      not_plottable()
    end
  end

  def module_plot(module, :acquisition, mode), do: module_plot(module, :readable, mode)
  def module_plot(_module, _interface_class, _mode), do: not_plottable()

  # Evaluate polynomial with ascending-order coefficients [c0, c1, c2, ...]
  # i.e. result = c0 + c1*x + c2*x^2 + ...
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

    # 1. target_limits
    case lookup_param_value.("target_limits") do
      [min, max] when is_number(min) and is_number(max) and min < max ->
        {min * 1.0, max * 1.0}

      _ ->
        target_param = Enum.find(module.parameters, fn p -> p.name == "target" end)
        target_datainfo = if target_param, do: target_param.datainfo || %{}, else: %{}

        # 2. target_min / target_max parameters, filling the missing bound from target datainfo
        target_min_val = lookup_param_value.("target_min")
        target_max_val = lookup_param_value.("target_max")

        datainfo_min = Map.get(target_datainfo, "min")
        datainfo_max = Map.get(target_datainfo, "max")

        resolved_min =
          cond do
            is_number(target_min_val) -> target_min_val * 1.0
            is_number(target_max_val) and is_number(datainfo_min) -> datainfo_min * 1.0
            # 3. min from target datainfo
            is_number(datainfo_min) -> datainfo_min * 1.0
            true -> nil
          end

        resolved_max =
          cond do
            is_number(target_max_val) -> target_max_val * 1.0
            is_number(target_min_val) and is_number(datainfo_max) -> datainfo_max * 1.0
            # 3. max from target datainfo
            is_number(datainfo_max) -> datainfo_max * 1.0
            true -> nil
          end

        case {resolved_min, resolved_max} do
          {min, max} when is_number(min) and is_number(max) and min < max ->
            {min, max}

          _ ->
            # 4. value datainfo
            value_param = Enum.find(module.parameters, fn p -> p.name == "value" end)
            value_datainfo = if value_param, do: value_param.datainfo || %{}, else: %{}
            val_min = Map.get(value_datainfo, "min")
            val_max = Map.get(value_datainfo, "max")

            if is_number(val_min) and is_number(val_max) and val_min < val_max do
              {val_min * 1.0, val_max * 1.0}
            else
              # 5. default
              {-50.0, 50.0}
            end
        end
    end
  end

  def calibration_plot(%SecantService.SecNodes.Module{} = module) do
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

    # Ranges

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
          # subplot 0 — forward calibration
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
          # subplot 1 — inverse calibration
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
          # subplot 2 — roundtrip
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
          # subplot 3 — roundtrip error
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
            %{left: "5%", top: "8%", width: "42%", height: "38%"},
            %{left: "55%", top: "8%", width: "42%", height: "38%"},
            %{left: "5%", top: "58%", width: "42%", height: "34%"},
            %{left: "55%", top: "58%", width: "42%", height: "34%"}
          ],
          xAxis: [
            %{gridIndex: 0, type: "value", name: "Setpoint#{unit_label}"},
            %{gridIndex: 1, type: "value", name: "Raw hardware value#{unit_label}"},
            %{gridIndex: 2, type: "value", name: "Setpoint#{unit_label}"},
            %{gridIndex: 3, type: "value", name: "Setpoint#{unit_label}"}
          ],
          yAxis: [
            %{gridIndex: 0, type: "value", name: "Hardware value#{unit_label}"},
            %{gridIndex: 1, type: "value", name: "Calibrated readback#{unit_label}"},
            %{gridIndex: 2, type: "value", name: "Calibrated readback#{unit_label}"},
            %{gridIndex: 3, type: "value", name: "Error#{unit_label}"}
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
            %{text: "Roundtrip Error", left: "76%", top: "51%", textAlign: "center",
              textStyle: %{fontSize: 12}}
          ],
          legend: %{orient: "vertical", right: 0, top: "center", type: "scroll"},
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

  def init(secop_obj, mode \\ :live) do
    case secop_obj do
      %SecantService.SecNodes.Parameter{} = param ->
        parameter_plot(param, mode)

      %SecantService.SecNodes.Module{} = module ->
        module_plot(module, mode)
    end
  end

  def drivable_plot(module, mode \\ :live), do: module_plot(module, :drivable, mode)

  def readable_plot(module, mode \\ :live), do: module_plot(module, :readable, mode)

  def parameter_plot(parameter, mode \\ :live) do
    plot_map = %{mode: mode}

    if plottable?(parameter) do
      {value_val, value_ts} =
        get_values(parameter)
        |> ParameterValue.extract_value_timestamp_lists(parameter)
        |> read_from_device_if_empty(parameter.id)

      base =
        plot_map
        |> Map.put(:plottable, true)
        |> get_unit(parameter)
        |> plot_available(value_val)

      case parameter.datainfo["type"] do
        "array" ->
          if value_val |> List.first([]) |> length() > @max_array_len do
            not_plottable()
          else
            base |> get_data_array(value_ts, value_val, parameter) |> get_layout_array() |> finalize()
          end

        _ ->
          base |> get_data(value_ts, value_val) |> get_layout() |> finalize()
      end
    else
      not_plottable()
    end
  end

  def no_plot_available() do
    %{plottable: true, plot_available: false}
  end

  def not_plottable() do
    %{plottable: false, plot_available: false, topics: []}
  end
end
