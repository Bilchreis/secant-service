defmodule SecantService.PlotDB do
  alias SecantService.Util

  alias SEC_Node_Statem

  alias SecantService.SecNodes.ParameterValue
  alias SecantService.SecNodes.Parameter
  alias SecantService.SecNodes.Module
  alias SecantService.NodeValues
  alias NodeTable
  require Logger

  @markersize 5

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

  def get_layout(%{plotly: nil, mode: :historical} = plot_map) do
    layout = %{
      xaxis: %{
        title: %{text: "Time"},
        type: "date",
        rangeslider: %{visible: false}
      },
      yaxis: %{title: %{text: "#{plot_map.unit}"}},
      margin: %{t: 10, b: 40, l: 50, r: 20},
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      autosize: true,
      height: 340
    }

    Map.put(plot_map, :layout, layout)
  end

  def get_layout(%{plotly: nil} = plot_map) do
    # Define the buttons first so we can reference them
    buttons = [
      %{count: 1, label: "1m", step: "minute", stepmode: "backward"},
      %{count: 10, label: "10m", step: "minute", stepmode: "backward"},
      %{count: 30, label: "30m", step: "minute", stepmode: "backward"},
      %{count: 1, label: "1h", step: "hour", stepmode: "backward"},
      %{count: 1, label: "1d", step: "day", stepmode: "backward"},
      %{step: "all", label: "all"}
    ]

    # Set which button should be active (0-based index)
    # This makes "10m" the default
    active_button_index = 1

    # Calculate the initial range based on the active button
    active_button = Enum.at(buttons, active_button_index)
    now = DateTime.utc_now()

    initial_range =
      case active_button do
        %{step: "all"} ->
          # Let Plotly auto-range for "all"
          nil

        %{step: "minute", count: count} ->
          start_time = DateTime.add(now, -count * 60, :second)
          [DateTime.to_iso8601(start_time), DateTime.to_iso8601(now)]

        %{step: "hour", count: count} ->
          start_time = DateTime.add(now, -count * 3600, :second)
          [DateTime.to_iso8601(start_time), DateTime.to_iso8601(now)]

        %{step: "day", count: count} ->
          start_time = DateTime.add(now, -count * 86400, :second)
          [DateTime.to_iso8601(start_time), DateTime.to_iso8601(now)]

        _ ->
          nil
      end

    layout = %{
      xaxis: %{
        title: %{text: "Time"},
        type: "date",
        # Set the initial range if we calculated one
        range: initial_range,
        rangeselector: %{
          buttons: buttons,
          # This makes the button appear selected
          active: active_button_index,
          x: 0,
          y: 1.02,
          xanchor: "left",
          yanchor: "bottom"
        },
        rangeslider: %{visible: false}
      },
      yaxis: %{title: %{text: "#{plot_map.unit}"}},
      margin: %{t: 10, b: 40, l: 50, r: 20},
      # background color of the chart container space,
      paper_bgcolor: "rgba(0,0,0,0",
      ## background color of plot area
      plot_bgcolor: "rgba(0,0,0,0)",
      autosize: true,
      height: 340
    }

    Map.put(plot_map, :layout, layout)
  end

  def get_layout(%{plotly: plotly} = plot_map) do
    layout = Map.get(plotly, "layout", [])

    Map.put(plot_map, :layout, layout)
  end

  defp get_element(value, path) do
    case path do
      [] ->
        value

      [key | tail] when is_binary(key) ->
        # Handle both string and atom keys
        result = Map.get(value, key) || Map.get(value, String.to_atom(key))
        get_element(result, tail)

      [index | tail] when is_integer(index) ->
        get_element(Enum.at(value, index), tail)
    end
  end

  defp map_to(key, nil), do: key

  defp map_to(key, map) do
    str_key = to_string(key)

    case Map.get(map, str_key, :not_found) do
      :not_found ->
        Logger.warning("Key #{inspect(str_key)} not found in map")
        nil

      value ->
        value
    end
  end

  defp default(value, nil) do
    value
  end

  defp default(_value, default) do
    default
  end

  defp process_plot_data(raw_data, plotly_specifier) do
    {type, path} = Map.get(plotly_specifier, "path", []) |> List.pop_at(0)
    parameter = Map.get(plotly_specifier, "parameter", "")
    indices = Map.get(plotly_specifier, "indices", "all")
    mapping = Map.get(plotly_specifier, "map_to", nil)
    default_val = Map.get(plotly_specifier, "default", nil)

    data =
      raw_data
      |> Map.get(parameter, [])
      |> Map.get(type, [])

    case indices do
      "all" ->
        # Use direct list comprehension instead of Enum.map
        for value <- data do
          get_element(value, path)
          |> map_to(mapping)
          |> default(default_val)
        end

      0 ->
        Enum.at(data, 0)
        |> get_element(path)
        |> map_to(mapping)
        |> default(default_val)
    end
  end

  # single parameter/readable with scalar data
  def get_data(%{plotly: nil} = plot_map, value_ts, value_val) do
    data = [
      %{
        x: value_ts,
        y: value_val,
        type: "scatter",
        mode: "lines+markers",
        name: "value",
        marker: %{size: @markersize}
      }
    ]

    Map.put(plot_map, :data, data)
  end

  # readable/single parameter with plotly specification
  def get_data(%{plotly: plotly} = plot_map, value_ts, value_val) do
    raw_data = %{
      "value" => %{"timestamp" => value_ts, "value" => value_val}
    }

    data = Map.get(plotly, "data", [])

    # Pre-process all plot data specifications once
    processed_cache = build_plot_data_cache(data, raw_data)

    data =
      Enum.reduce(data, [], fn trace, data_acc ->
        new_data =
          Enum.reduce(trace, %{}, fn {key, value}, acc ->
            acc = Map.put(acc, key, value)

            case value do
              # Plotly path and parameter
              %{"path" => _path, "parameter" => _parameter} ->
                cache_key = {key, value}
                Map.put(acc, key, Map.get(processed_cache, cache_key))

              # Standard plotly specifier
              _ ->
                Map.put(acc, key, value)
            end
          end)

        [new_data | data_acc]
      end)

    data = Enum.reverse(data)
    Map.put(plot_map, :data, data)
  end

  # drivable with scalar data
  def get_data(%{plotly: nil} = plot_map, value_ts, value_val, target_ts, target_val) do
    data = [
      %{
        x: value_ts,
        y: value_val,
        type: "scatter",
        mode: "lines+markers",
        name: "value",
        marker: %{size: @markersize}
      },
      %{
        x: target_ts,
        y: target_val,
        type: "scatter",
        mode: "lines+markers",
        name: "target",
        marker: %{size: @markersize}
      }
    ]

    Map.put(plot_map, :data, data)
  end

  # calibratable with scalar data
  def get_data(
        %{plotly: nil} = plot_map,
        value_ts,
        value_val,
        value_uncalibrated_ts,
        value_uncalibrated_val,
        target_ts,
        target_val,
        target_calibrated_ts,
        target_calibrated_val
      ) do
    data = [
      %{
        x: value_ts,
        y: value_val,
        type: "scatter",
        mode: "lines+markers",
        name: "value",
        marker: %{size: @markersize}
      },
      %{
        x: target_ts,
        y: target_val,
        type: "scatter",
        mode: "lines+markers",
        name: "target",
        marker: %{size: @markersize}
      },
      %{
        x: value_uncalibrated_ts,
        y: value_uncalibrated_val,
        type: "scatter",
        mode: "lines+markers",
        name: "_value_uncalibrated",
        marker: %{size: @markersize},
        visible: "legendonly"
      },
      %{
        x: target_calibrated_ts,
        y: target_calibrated_val,
        type: "scatter",
        mode: "lines+markers",
        name: "_target_calibrated",
        marker: %{size: @markersize},
        visible: "legendonly"
      }
    ]

    Map.put(plot_map, :data, data)
  end

  # drivable with plotly specification
  def get_data(%{plotly: plotly} = plot_map, value_ts, value_val, target_ts, target_val) do
    raw_data = %{
      "value" => %{"timestamp" => value_ts, "value" => value_val},
      "target" => %{"timestamp" => target_ts, "value" => target_val}
    }

    data = Map.get(plotly, "data", [])

    processed_cache = build_plot_data_cache(data, raw_data)

    data =
      Enum.reduce(data, [], fn trace, data_acc ->
        new_data =
          Enum.reduce(trace, %{}, fn {key, value}, acc ->
            acc = Map.put(acc, key, value)

            case value do
              # Use cached processed data
              %{"path" => _path, "parameter" => _parameter} ->
                cache_key = {key, value}
                Map.put(acc, key, Map.get(processed_cache, cache_key))

              _ ->
                Map.put(acc, key, value)
            end
          end)

        [new_data | data_acc]
      end)

    data = Enum.reverse(data)
    Map.put(plot_map, :data, data)
  end

  # Build a cache of all processed plot data upfront
  defp build_plot_data_cache(traces, raw_data) do
    traces
    |> Enum.flat_map(fn trace ->
      Enum.filter(trace, fn {_key, value} ->
        match?(%{"path" => _, "parameter" => _}, value)
      end)
    end)
    |> Map.new(fn {key, spec} ->
      {{key, spec}, process_plot_data(raw_data, spec)}
    end)
  end

  def get_trace_updates_batch(%{plotly: nil} = plot_map, datapoints, parameter) do
    trace_index =
      Enum.find_index(plot_map.data, fn trace ->
        trace[:name] == parameter
      end) || 0

    # Extract all timestamps and values from the batch
    {values, timestamps} = Enum.unzip(datapoints)

    # Format data for the extend-traces event
    # The event expects arrays of arrays (one per trace)
    %{
      # Add one timestamp to the specified trace
      x: [timestamps],
      # Add one value to the specified trace
      y: [values],
      traceIndices: [trace_index]
    }
  end

  def get_trace_updates_batch(%{plotly: _plotly} = plot_map, datapoints, parameter) do
    trace_data =
      Enum.reduce(datapoints, %{}, fn {value, timestamp}, acc ->
        update = get_trace_updates(plot_map, value, timestamp, parameter)

        Map.merge(acc, update, fn _key, {x1, y1}, {x2, y2} ->
          {x1 ++ x2, y1 ++ y2}
        end)
      end)

    # Convert to Plotly format: %{x: [[...], [...]], y: [[...], [...]], traceIndices: [0, 1]}
    # Sort by trace index to ensure consistent ordering
    trace_data
    |> Enum.sort_by(fn {index, _data} -> index end)
    |> Enum.reduce(%{x: [], y: [], traceIndices: []}, fn {index, {x, y}}, acc ->
      %{
        x: acc.x ++ [x],
        y: acc.y ++ [y],
        traceIndices: acc.traceIndices ++ [index]
      }
    end)
  end

  # Get the updates for an incoming datareport with plotly specification
  def get_trace_updates(%{plotly: plotly} = _plot_map, value, timestamp, parameter) do
    raw_data = %{
      parameter => %{"timestamp" => [timestamp], "value" => [value]}
    }

    # Only collect traces that match the parameter
    matching_traces =
      plotly["data"]
      |> Enum.with_index()
      |> Enum.filter(fn {trace, _index} ->
        Map.get(trace, "parameter", "") == parameter
      end)

    # If no matching traces, return empty update
    update =
      if Enum.empty?(matching_traces) do
        %{}
      else
        # Process only the matching traces
        Enum.reduce(matching_traces, %{}, fn {trace, index}, acc ->
          {x, y, trace_indices} = get_extension(trace, index, raw_data)

          Map.put(acc, trace_indices, {x, y})
        end)
      end

    update
  end

  def get_extension(trace, trace_index, raw_data) do
    xdata =
      if Map.has_key?(trace, "x") do
        process_plot_data(raw_data, trace["x"])
      else
        [nil]
      end

    ydata =
      if Map.has_key?(trace, "y") do
        process_plot_data(raw_data, trace["y"])
      else
        [nil]
      end

    {xdata, ydata, trace_index}
  end

  def plottable?(%SecantService.SecNodes.Parameter{} = parameter) do
    has_plotly_property = Map.has_key?(parameter.custom_properties || %{}, "_plotly")

    case parameter.datainfo["type"] do
      numeric when numeric in ["double", "int", "scaled"] -> true
      # TODO
      "bool" -> has_plotly_property
      # TODO
      "enum" -> has_plotly_property
      # TODO
      "array" -> has_plotly_property
      _ -> has_plotly_property
    end
  end

  def plottable?(%SecantService.SecNodes.Module{} = module) do
    value_param = Enum.find(module.parameters, fn param -> param.name == "value" end)

    case value_param do
      nil -> false
      param -> plottable?(param) or Map.has_key?(module.custom_properties || %{}, "_plotly")
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
        |> Map.put(:plotly, Map.get(module.custom_properties || %{}, "_plotly", nil))

      {value_val, value_ts} =
        get_values(value_param)
        |> ParameterValue.extract_value_timestamp_lists(value_param)
        |> read_from_device_if_empty(value_param.id)

      plot_map
      |> plot_available(value_val)
      |> get_data(value_ts, value_val)
      |> get_layout()
      |> Map.put(:config, %{responsive: true, displayModeBar: false})
    else
      not_plottable()
    end
  end

  def module_plot(module, :drivable, mode) do
    plot_map = %{mode: mode}

    value_param = Enum.find(module.parameters, fn param -> param.name == "value" end)
    target_param = Enum.find(module.parameters, fn param -> param.name == "target" end)

    if plottable?(value_param) or Map.has_key?(module.custom_properties || %{}, "_plotly") do
      plot_map =
        Map.put(plot_map, :plottable, true)
        |> get_unit(value_param)
        |> Map.put(:plotly, Map.get(module.custom_properties || %{}, "_plotly", nil))

      {value_val, value_ts} =
        get_values(value_param)
        |> ParameterValue.extract_value_timestamp_lists(value_param)
        |> read_from_device_if_empty(value_param.id)

      {target_val, target_ts} =
        get_values(target_param)
        |> ParameterValue.extract_value_timestamp_lists(target_param)
        |> read_from_device_if_empty(target_param.id)

      plot_map
      |> plot_available(value_val)
      |> get_data(value_ts, value_val, target_ts, target_val)
      |> get_layout()
      |> Map.put(:config, %{responsive: true, displayModeBar: false})
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

    if plottable?(value_param) or Map.has_key?(module.custom_properties || %{}, "_plotly") do
      plot_map =
        Map.put(plot_map, :plottable, true)
        |> get_unit(value_param)
        |> Map.put(:plotly, Map.get(module.custom_properties || %{}, "_plotly", nil))

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
      |> Map.put(:config, %{responsive: true, displayModeBar: false})
    else
      not_plottable()
    end
  end

  def module_plot(_module, :acquisition, mode), do: module_plot(_module, :readable, mode)
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

        identity_style = %{color: "gray", dash: "dash"}

        data = [
          # --- subplot 1: forward ---
          %{
            x: setpoints,
            y: hw_values,
            type: "scatter",
            mode: "lines",
            name: "hardware value",
            line: %{color: "steelblue"},
            xaxis: "x",
            yaxis: "y"
          },
          %{
            x: setpoints,
            y: setpoints,
            type: "scatter",
            mode: "lines",
            name: "identity",
            line: identity_style,
            opacity: 0.5,
            showlegend: false,
            xaxis: "x",
            yaxis: "y"
          },
          # --- subplot 2: inverse ---
          %{
            x: hw_values,
            y: calib_readback,
            type: "scatter",
            mode: "lines",
            name: "calibrated readback",
            line: %{color: "crimson"},
            xaxis: "x2",
            yaxis: "y2"
          },
          %{
            x: hw_values,
            y: hw_values,
            type: "scatter",
            mode: "lines",
            name: "identity2",
            line: identity_style,
            opacity: 0.5,
            showlegend: false,
            xaxis: "x2",
            yaxis: "y2"
          },
          # --- subplot 3: roundtrip ---
          %{
            x: setpoints,
            y: calib_readback,
            type: "scatter",
            mode: "lines",
            name: "roundtrip result",
            line: %{color: "seagreen"},
            xaxis: "x3",
            yaxis: "y3"
          },
          %{
            x: setpoints,
            y: setpoints,
            type: "scatter",
            mode: "lines",
            name: "identity3",
            line: identity_style,
            opacity: 0.5,
            showlegend: false,
            xaxis: "x3",
            yaxis: "y3"
          },
          # --- subplot 4: error ---
          %{
            x: setpoints,
            y: roundtrip_err,
            type: "scatter",
            mode: "lines",
            name: "roundtrip error",
            line: %{color: "mediumpurple"},
            xaxis: "x4",
            yaxis: "y4"
          }
        ]

        layout = %{
          grid: %{rows: 2, columns: 2, pattern: "independent"},
          xaxis: %{title: %{text: "Setpoint#{unit_label}"}, gridcolor: "rgba(128,128,128,0.3)"},
          yaxis: %{
            title: %{text: "Hardware value#{unit_label}"},
            gridcolor: "rgba(128,128,128,0.3)"
          },
          xaxis2: %{
            title: %{text: "Raw hardware value#{unit_label}"},
            gridcolor: "rgba(128,128,128,0.3)"
          },
          yaxis2: %{
            title: %{text: "Calibrated readback#{unit_label}"},
            gridcolor: "rgba(128,128,128,0.3)"
          },
          xaxis3: %{title: %{text: "Setpoint#{unit_label}"}, gridcolor: "rgba(128,128,128,0.3)"},
          yaxis3: %{
            title: %{text: "Calibrated readback#{unit_label}"},
            gridcolor: "rgba(128,128,128,0.3)"
          },
          xaxis4: %{title: %{text: "Setpoint#{unit_label}"}, gridcolor: "rgba(128,128,128,0.3)"},
          yaxis4: %{
            title: %{text: "Error#{unit_label}"},
            gridcolor: "rgba(128,128,128,0.3)",
            zeroline: true,
            zerolinecolor: "gray",
            zerolinewidth: 1
          },
          paper_bgcolor: "rgba(0,0,0,0)",
          plot_bgcolor: "rgba(0,0,0,0)",
          autosize: true,
          height: 700,
          margin: %{t: 50, b: 50, l: 60, r: 20},
          annotations: [
            %{
              text: "Forward Calibration: Setpoint → Hardware",
              showarrow: false,
              x: 0.225,
              xref: "paper",
              y: 1.04,
              yref: "paper",
              xanchor: "center",
              font: %{size: 12}
            },
            %{
              text: "Inverse Calibration: Hardware → Readback",
              showarrow: false,
              x: 0.775,
              xref: "paper",
              y: 1.04,
              yref: "paper",
              xanchor: "center",
              font: %{size: 12}
            },
            %{
              text: "Roundtrip: Setpoint → Forward → Inverse",
              showarrow: false,
              x: 0.225,
              xref: "paper",
              y: 0.46,
              yref: "paper",
              xanchor: "center",
              font: %{size: 12}
            },
            %{
              text: "Roundtrip Error",
              showarrow: false,
              x: 0.775,
              xref: "paper",
              y: 0.46,
              yref: "paper",
              xanchor: "center",
              font: %{size: 12}
            }
          ]
        }

        %{
          plottable: true,
          plot_available: true,
          data: data,
          layout: layout,
          config: %{responsive: true, displayModeBar: false},
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

    plot_map =
      if plottable?(parameter) do
        {value_val, value_ts} =
          get_values(parameter)
          |> ParameterValue.extract_value_timestamp_lists(parameter)
          |> read_from_device_if_empty(parameter.id)

        plot_map =
          Map.put(plot_map, :plottable, true)
          |> get_unit(parameter)
          |> Map.put(:plotly, Map.get(parameter.custom_properties, "_plotly", nil))

        plot_map = plot_available(plot_map, value_val)

        plot_map =
          plot_map
          |> get_data(value_ts, value_val)
          |> get_layout()

        config =
          %{
            responsive: true,
            displayModeBar: false
          }

        Map.put(plot_map, :config, config)
      else
        not_plottable()
      end

    plot_map
  end

  def no_plot_available() do
    %{plottable: true, plot_available: false}
  end

  def not_plottable() do
    %{plottable: false, plot_available: false, topics: []}
  end
end
