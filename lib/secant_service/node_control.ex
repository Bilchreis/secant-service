defmodule SecantService.NodeControl do
  require Logger
  alias SecantClient.NodeStatem

  def change(unsigned_params) do
    nodeid =
      {String.to_charlist(unsigned_params["host"]), String.to_integer(unsigned_params["port"])}

    module = unsigned_params["module"]
    parameter = unsigned_params["parameter"]
    value = unsigned_params["value"]

    NodeStatem.change(nodeid, module, parameter, value)
  end

  def execute_command(unsigned_params) do
    nodeid =
      {String.to_charlist(unsigned_params["host"]), String.to_integer(unsigned_params["port"])}

    module = unsigned_params["module"]
    command = unsigned_params["command"]
    value = unsigned_params["value"]

    NodeStatem.execute_command(nodeid, module, command, value)
  end

  # Datainfo and values are handled with string keys, exactly as they come
  # from the database and the JSON the user typed. Nothing here creates
  # atoms from user input.

  # Navigate from the top-level datainfo to the datainfo of a nested form
  # field such as "value.position.f1". Returns nil for a path that does not
  # exist in the datainfo.
  defp get_datainfo_by_path(datainfo, ["value"]), do: datainfo
  defp get_datainfo_by_path(datainfo, []), do: datainfo
  defp get_datainfo_by_path(datainfo, ["value" | rest]), do: get_datainfo_by_path(datainfo, rest)

  defp get_datainfo_by_path(datainfo, [key | rest]) do
    case member_info(datainfo, key) do
      {:ok, member_info} -> get_datainfo_by_path(member_info, rest)
      :error -> nil
    end
  end

  defp member_info(%{"type" => "struct", "members" => members}, key) do
    Map.fetch(members, key)
  end

  defp member_info(%{"type" => "tuple", "members" => members}, key) do
    case tuple_index(key) do
      {:ok, index} when index < length(members) -> {:ok, Enum.at(members, index)}
      _ -> :error
    end
  end

  defp member_info(_datainfo, _key), do: :error

  defp tuple_index("f" <> digits) do
    case Integer.parse(digits) do
      {index, ""} when index >= 0 -> {:ok, index}
      _ -> :error
    end
  end

  defp tuple_index(_key), do: :error

  # Write `target` into `value` at `path`, following the datainfo.
  defp put_validated(_value, _datainfo, ["value"], target), do: target
  defp put_validated(_value, _datainfo, [], target), do: target

  defp put_validated(value, datainfo, ["value" | rest], target),
    do: put_validated(value, datainfo, rest, target)

  defp put_validated(value, %{"type" => "struct"} = datainfo, [key | rest], target)
       when is_map(value) do
    case member_info(datainfo, key) do
      {:ok, info} -> Map.put(value, key, put_validated(Map.get(value, key), info, rest, target))
      :error -> value
    end
  end

  defp put_validated(value, %{"type" => "tuple"} = datainfo, [key | rest], target)
       when is_list(value) do
    with {:ok, info} <- member_info(datainfo, key),
         {:ok, index} <- tuple_index(key),
         true <- index < length(value) do
      List.replace_at(value, index, put_validated(Enum.at(value, index), info, rest, target))
    else
      _ -> value
    end
  end

  defp put_validated(value, _datainfo, _path, _target), do: value

  # The top-level field is read in templates as `form[:value]`, nested fields
  # as `form["value.member"]`; Phoenix.HTML.Form matches errors by that exact
  # key, so only "value" is an atom.
  defp error_key("value"), do: :value
  defp error_key(target) when is_binary(target), do: target

  defp has_error?(form, target), do: List.keymember?(form.errors, error_key(target), 0)

  defp put_error(form, target, msg),
    do: %{
      form
      | errors: List.keystore(form.errors, error_key(target), 0, {error_key(target), {msg, []}})
    }

  defp delete_error(form, target),
    do: %{form | errors: List.keydelete(form.errors, error_key(target), 0)}

  def validate_modal(unsigned_params, datainfo, modal_form) do
    targets = List.wrap(unsigned_params["_target"])

    modal_form =
      Enum.reduce(targets, modal_form, fn target, form ->
        path = String.split(target, ".")

        case get_datainfo_by_path(datainfo, path) do
          nil ->
            # not a field of this parameter (e.g. a hidden input)
            form

          field_info ->
            form = validate_field(unsigned_params[target], target, field_info, form)
            merge_into_value(form, unsigned_params, target, path, datainfo)
        end
      end)

    unsigned_params = Map.put(unsigned_params, "value", modal_form.params["value"])

    # Finally, validate the entire value field to ensure overall consistency
    validate_field(unsigned_params["value"], "value", datainfo, modal_form)
  end

  # Copy a valid member field into the JSON of the whole value. Skipped for the
  # value field itself and while the whole value is not valid JSON.
  defp merge_into_value(form, _params, "value", _path, _datainfo), do: form

  defp merge_into_value(form, params, target, path, datainfo) do
    with false <- has_error?(form, target),
         {:ok, value} <- Jason.decode(params["value"] || ""),
         {:ok, member} <- Jason.decode(params[target] || "") do
      updated = value |> put_validated(datainfo, path, member) |> Jason.encode!(pretty: true)

      %{
        form
        | params: Map.put(form.params, "value", updated),
          source: Map.put(form.source, "value", updated)
      }
    else
      _ -> form
    end
  end

  def validate_field(new_field_value, target, datainfo, form) do
    case Jason.decode(new_field_value || "") do
      {:ok, value} ->
        case validate_against_datainfo(datainfo, value) do
          {:ok, _} ->
            form = delete_error(form, target)

            %{
              form
              | params: Map.put(form.params, target, new_field_value),
                source: Map.put(form.source, target, new_field_value)
            }

          {:error, msg} ->
            put_error(form, target, msg)
        end

      {:error, _} ->
        put_error(form, target, "Invalid JSON format")
    end
  end

  def validate(unsigned_params, datainfo, set_form) do
    case decode_input(unsigned_params["value"], datainfo) do
      {:ok, value} ->
        case validate_against_datainfo(datainfo, value) do
          {:ok, _} ->
            # Add validation indicator AND update the form's value
            pretty_value = Jason.encode!(value, pretty: true)

            set_form = %{
              set_form
              | params: Map.put(set_form.params, "value", pretty_value),
                source: Map.put(set_form.source, "value", pretty_value),
                errors: []
            }

            set_form

          {:error, msg} ->
            # Field-specific error
            %{set_form | errors: [value: {msg, []}]}
        end

      {:error, _} ->
        %{set_form | errors: parse_errors(unsigned_params["value"], datainfo)}
    end
  end

  # Plain text typed into a string parameter does not need JSON quotes.
  defp decode_input(raw, %{"type" => "string"}) when is_binary(raw) and raw != "" do
    case Jason.decode(raw) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:ok, raw}
    end
  end

  defp decode_input(raw, _datainfo), do: Jason.decode(raw || "")

  # Messages for input that is not valid JSON, phrased for the person typing
  # rather than in terms of JSON. An empty field is not an error while typing.
  defp parse_errors(raw, datainfo) do
    raw = String.trim(raw || "")
    type = datainfo["type"]

    cond do
      raw == "" ->
        []

      type in ["double", "scaled", "int"] and Regex.match?(~r/^[+-]?\d*,\d+$/, raw) ->
        [value: {"Use a decimal point, e.g. #{String.replace(raw, ",", ".")}", []}]

      type in ["double", "scaled", "int"] ->
        [value: {"Not a number", []}]

      true ->
        [value: {"Invalid JSON format", []}]
    end
  end

  def validate_against_datainfo(datainfo, value) do
    case datainfo["type"] do
      "double" ->
        validate_double(datainfo, value)

      "int" ->
        validate_int(datainfo, value)

      "scaled" ->
        validate_scaled(datainfo, value)

      "bool" ->
        validate_bool(datainfo, value)

      "enum" ->
        validate_enum(datainfo, value)

      "string" ->
        validate_string(datainfo, value)

      "blob" ->
        validate_blob(datainfo, value)

      "array" ->
        validate_array(datainfo, value)

      "tuple" ->
        validate_tuple(datainfo, value)

      "struct" ->
        validate_struct(datainfo, value)

      "matrix" ->
        validate_matrix(datainfo, value)

      _ ->
        Logger.error("Unknown data type: #{inspect(datainfo)}")
        {:error, "Unknown data type"}
    end
  end

  def validate_double(datainfo, value) do
    cond do
      not is_number(value) ->
        {:error, "Value must be a number"}

      Map.has_key?(datainfo, "min") and value < datainfo["min"] ->
        {:error, "Value #{value} is below minimum #{datainfo["min"]}"}

      Map.has_key?(datainfo, "max") and value > datainfo["max"] ->
        {:error, "Value #{value} is above maximum #{datainfo["max"]}"}

      true ->
        {:ok, value}
    end
  end

  def validate_int(datainfo, value) do
    cond do
      not is_integer(value) ->
        {:error, "Value must be an integer"}

      Map.has_key?(datainfo, "min") and value < datainfo["min"] ->
        {:error, "Value #{value} is below minimum #{datainfo["min"]}"}

      Map.has_key?(datainfo, "max") and value > datainfo["max"] ->
        {:error, "Value #{value} is above maximum #{datainfo["max"]}"}

      true ->
        {:ok, value}
    end
  end

  def validate_scaled(datainfo, value) do
    validate_int(datainfo, value)
  end

  def validate_bool(_datainfo, value) do
    if is_boolean(value) do
      {:ok, value}
    else
      {:error, "Value must be true or false"}
    end
  end

  def validate_enum(datainfo, value) do
    if not is_integer(value) do
      {:error, "Enum value must be an integer"}
    else
      # Check if value is in the members values
      if Map.values(datainfo["members"]) |> Enum.member?(value) do
        {:ok, value}
      else
        valid_values = Map.values(datainfo["members"]) |> Enum.join(", ")
        {:error, "Invalid enum value. Must be one of: #{valid_values}"}
      end
    end
  end

  def validate_string(datainfo, value) do
    cond do
      not is_binary(value) ->
        {:error, "Value must be a string"}

      Map.has_key?(datainfo, "maxchars") and String.length(value) > datainfo["maxchars"] ->
        {:error, "String exceeds maximum length of #{datainfo["maxchars"]} characters"}

      Map.has_key?(datainfo, "minchars") and String.length(value) < datainfo["minchars"] ->
        {:error, "String is shorter than minimum length of #{datainfo["minchars"]} characters"}

      Map.get(datainfo, "isUTF8", false) == false and
          String.to_charlist(value) |> Enum.any?(fn c -> c > 127 end) ->
        {:error, "String contains non-ASCII characters"}

      true ->
        {:ok, value}
    end
  end

  def validate_blob(datainfo, value) do
    try do
      decoded = Base.decode64!(value)
      size = byte_size(decoded)

      cond do
        Map.has_key?(datainfo, "maxbytes") and size > datainfo["maxbytes"] ->
          {:error, "Blob exceeds maximum size of #{datainfo["maxbytes"]} bytes"}

        Map.has_key?(datainfo, "minbytes") and size < datainfo["minbytes"] ->
          {:error, "Blob is smaller than minimum size of #{datainfo["minbytes"]} bytes"}

        true ->
          {:ok, value}
      end
    rescue
      _ -> {:error, "Invalid base64 encoded string"}
    end
  end

  def validate_array(datainfo, value) do
    if not is_list(value) do
      {:error, "Value must be an array"}
    else
      size = length(value)

      cond do
        Map.has_key?(datainfo, "maxlen") and size > datainfo["maxlen"] ->
          {:error, "Array exceeds maximum length of #{datainfo["maxlen"]} items"}

        Map.has_key?(datainfo, "minlen") and size < datainfo["minlen"] ->
          {:error, "Array is shorter than minimum length of #{datainfo["minlen"]} items"}

        true ->
          # Validate each element against the member type
          results = Enum.map(value, &validate_against_datainfo(datainfo["members"], &1))
          errors = Enum.filter(results, fn {status, _} -> status == :error end)

          if Enum.empty?(errors) do
            {:ok, value}
          else
            # Return first error
            hd(errors)
          end
      end
    end
  end

  def validate_tuple(datainfo, value) do
    if not is_list(value) do
      {:error, "Value must be a tuple (JSON array)"}
    else
      value_size = length(value)
      expected_size = length(datainfo["members"])

      if value_size != expected_size do
        {:error, "Tuple must have exactly #{expected_size} elements, got #{value_size}"}
      else
        # Validate each element against corresponding member type
        results =
          Enum.zip(value, datainfo["members"])
          |> Enum.map(fn {val, type} -> validate_against_datainfo(type, val) end)

        errors = Enum.filter(results, fn {status, _} -> status == :error end)

        if Enum.empty?(errors) do
          {:ok, value}
        else
          # Return first error
          hd(errors)
        end
      end
    end
  end

  def validate_struct(datainfo, value) do
    if not is_map(value) do
      {:error, "Value must be a struct (JSON object)"}
    else
      # Get required member keys (all members except optional ones)
      optional_members = Map.get(datainfo, "optional", [])
      required_keys = Map.keys(datainfo["members"]) -- optional_members

      # Check if all required keys are present
      missing_keys = Enum.filter(required_keys, fn key -> not Map.has_key?(value, key) end)

      if not Enum.empty?(missing_keys) do
        {:error, "Missing required fields: #{Enum.join(missing_keys, ", ")}"}
      else
        # Validate each present field against its type definition
        results =
          for {k, v} <- value, Map.has_key?(datainfo["members"], k) do
            member_type = datainfo["members"][k]
            {k, validate_against_datainfo(member_type, v)}
          end

        errors = Enum.filter(results, fn {_, {status, _}} -> status == :error end)

        if Enum.empty?(errors) do
          {:ok, value}
        else
          # Return first error with field name
          {field, {_, msg}} = hd(errors)
          {:error, "Field '#{field}': #{msg}"}
        end
      end
    end
  end

  def validate_matrix(datainfo, value) do
    # Matrix is transmitted as a JSON object with "len" and "blob" fields
    if not is_map(value) do
      {:error, "Matrix must be a JSON object"}
    else
      if not (Map.has_key?(value, "len") and Map.has_key?(value, "blob")) do
        {:error, "Matrix must have 'len' and 'blob' fields"}
      else
        len = value["len"]
        blob = value["blob"]

        # Validate dimensions
        if not is_list(len) do
          {:error, "Matrix 'len' field must be an array"}
        else
          expected_dimensions = length(datainfo["names"])
          actual_dimensions = length(len)

          if expected_dimensions != actual_dimensions do
            {:error,
             "Matrix has wrong number of dimensions (expected #{expected_dimensions}, got #{actual_dimensions})"}
          else
            # Check dimension lengths against maxlen
            dim_errors =
              Enum.zip(len, datainfo["maxlen"])
              |> Enum.filter(fn {actual, max} -> actual > max end)

            if not Enum.empty?(dim_errors) do
              {actual, max} = hd(dim_errors)
              {:error, "Matrix dimension exceeds maximum length (#{actual} > #{max})"}
            else
              try do
                # Try to decode the blob (just for validation)
                _decoded = Base.decode64!(blob)
                {:ok, value}
              rescue
                _ -> {:error, "Invalid base64 encoded matrix data"}
              end
            end
          end
        end
      end
    end
  end
end
