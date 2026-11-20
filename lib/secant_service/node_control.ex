defmodule SecantService.NodeControl do
  require Logger
  alias SecantClient.NodeStatem
  alias Jason

  # Add this helper function to convert string keys to atoms recursively
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {string_to_atom(k), atomize_keys(v)} end)
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(value), do: value

  defp string_to_atom(key) when is_binary(key), do: String.to_atom(key)
  defp string_to_atom(key), do: key

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

  defp get_datainfo_by_path(datainfo, ["value"]), do: datainfo

  defp get_datainfo_by_path(datainfo, []), do: datainfo

  defp get_datainfo_by_path(datainfo, ["value" | rest]) do
    get_datainfo_by_path(datainfo, rest)
  end

  defp get_datainfo_by_path(datainfo, [key | rest]) do
    key_atom = String.to_atom(key)

    case datainfo[:type] do
      "struct" ->
        if Map.has_key?(datainfo.members, key_atom) do
          member_info = datainfo.members[key_atom]
          get_datainfo_by_path(member_info, rest)
        else
          Logger.error("Key #{key} not found in struct members #{inspect(datainfo.members)}")
        end

      "tuple" ->
        index = String.replace_prefix(key, "f", "") |> String.to_integer()

        if index < length(datainfo.members) do
          member_info = Enum.at(datainfo.members, index)
          get_datainfo_by_path(member_info, rest)
        else
          Logger.error(
            "Index #{index} out of bounds for tuple members #{inspect(datainfo.members)}"
          )
        end

      _ ->
        Logger.error("Cannot navigate into type #{datainfo[:type]} with key #{key}")
        nil
    end
  end

  defp put_validated(value, datainfo, path, target) do
    case path do
      ["value"] ->
        target

      ["value" | rest] ->
        put_validated(value, datainfo, rest, target)

      [key | rest] ->
        key_atom = String.to_atom(key)

        case datainfo[:type] do
          "struct" ->
            if Map.has_key?(datainfo.members, key_atom) do
              member_info = datainfo.members[key_atom]

              updated_subvalue =
                put_validated(Map.get(value, key_atom), member_info, rest, target)

              Map.put(value, key_atom, updated_subvalue)
            else
              Logger.error("Key #{key} not found in struct members #{inspect(datainfo.members)}")
              value
            end

          "tuple" ->
            index = String.replace_prefix(key, "f", "") |> String.to_integer()

            if index < length(datainfo.members) do
              member_info = Enum.at(datainfo.members, index)
              current_subvalue = Enum.at(value, index)
              updated_subvalue = put_validated(current_subvalue, member_info, rest, target)
              List.replace_at(value, index, updated_subvalue)
            else
              Logger.error(
                "Index #{index} out of bounds for tuple members #{inspect(datainfo.members)}"
              )

              value
            end

          _ ->
            Logger.error("Cannot navigate into type #{datainfo[:type]} with key #{key}")
            value
        end

      [] ->
        target
    end
  end

  def validate_modal(unsigned_params, datainfo, modal_form) do
    targets = unsigned_params["_target"]
    Logger.info("Validating field: #{inspect(targets)}")

    atomized_datainfo = atomize_keys(datainfo)

    paths =
      Enum.reduce(targets, [], fn target, acc ->
        [String.split(target, ".", []) | acc]
      end)

    fields = Enum.zip(targets, paths)

    modal_form =
      Enum.reduce(fields, modal_form, fn {target, path}, form ->
        ## get datainfo for target field according to path
        field_info = get_datainfo_by_path(atomized_datainfo, path)

        form = validate_field(unsigned_params[target], target, field_info, form)

        ## update form["value"] with the validated target field value ( skip if target == "value",
        # also skip if there are  json format errors listed for the "value field")
        error_msg =
          case Keyword.get(form.errors, :value) do
            {msg, _} -> msg
            _ -> nil
          end

        if not Keyword.has_key?(form.errors, string_to_atom(target)) and target != "value" and
             error_msg != "Invalid JSON format" do
          val_decoded = Jason.decode!(unsigned_params["value"], keys: :atoms)
          target_decoded = Jason.decode!(unsigned_params[target], keys: :atoms)

          val_updated =
            put_validated(val_decoded, atomized_datainfo, path, target_decoded)
            |> Jason.encode!(pretty: true)

          %{
            form
            | params: Map.put(form.params, "value", val_updated),
              source: Map.put(form.source, "value", val_updated)
          }
        else
          form
        end
      end)

    unsigned_params = Map.put(unsigned_params, "value", modal_form.params["value"])

    # Finally, validate the entire value field to ensure overall consistency
    validate_field(unsigned_params["value"], "value", atomized_datainfo, modal_form)
  end

  def validate_field(new_field_value, target, datainfo, form) do
    target_atom = String.to_atom(target)

    case Jason.decode(new_field_value, keys: :atoms) do
      {:ok, value} ->
        case validate_against_datainfo(datainfo, value) do
          {:ok, _} ->
            # Add validation indicator AND update the form's value

            form =
              if Keyword.has_key?(form.errors, target_atom) do
                Logger.info("Clearing errors for field #{target}")
                %{form | errors: Keyword.delete(form.errors, target_atom)}
              else
                form
              end

            form = %{
              form
              | params: Map.put(form.params, target, new_field_value),
                source: Map.put(form.source, target, new_field_value)
            }

            form

          {:error, msg} ->
            # Field-specific error - extend existing errors
            %{form | errors: Keyword.put(form.errors, target_atom, {msg, []})}
        end

      {:error, _} ->
        # Field-specific JSON error - extend existing errors
        %{form | errors: Keyword.put(form.errors, target_atom, {"Invalid JSON format", []})}
    end
  end

  def validate(unsigned_params, datainfo, set_form) do
    # Convert datainfo string keys to atoms
    atomized_datainfo = atomize_keys(datainfo)

    case decode_input(unsigned_params["value"], datainfo) do
      {:ok, value} ->
        case validate_against_datainfo(atomized_datainfo, value) do
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

  defp decode_input(raw, _datainfo), do: Jason.decode(raw || "", keys: :atoms)

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
    # Changed from datainfo["type"] to datainfo[:type]
    case datainfo[:type] do
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

      Map.has_key?(datainfo, :min) and value < datainfo.min ->
        {:error, "Value #{value} is below minimum #{datainfo.min}"}

      Map.has_key?(datainfo, :max) and value > datainfo.max ->
        {:error, "Value #{value} is above maximum #{datainfo.max}"}

      true ->
        {:ok, value}
    end
  end

  def validate_int(datainfo, value) do
    cond do
      not is_integer(value) ->
        {:error, "Value must be an integer"}

      Map.has_key?(datainfo, :min) and value < datainfo.min ->
        {:error, "Value #{value} is below minimum #{datainfo.min}"}

      Map.has_key?(datainfo, :max) and value > datainfo.max ->
        {:error, "Value #{value} is above maximum #{datainfo.max}"}

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
      if Map.values(datainfo.members) |> Enum.member?(value) do
        {:ok, value}
      else
        valid_values = Map.values(datainfo.members) |> Enum.join(", ")
        {:error, "Invalid enum value. Must be one of: #{valid_values}"}
      end
    end
  end

  def validate_string(datainfo, value) do
    cond do
      not is_binary(value) ->
        {:error, "Value must be a string"}

      Map.has_key?(datainfo, :maxchars) and String.length(value) > datainfo.maxchars ->
        {:error, "String exceeds maximum length of #{datainfo.maxchars} characters"}

      Map.has_key?(datainfo, :minchars) and String.length(value) < datainfo.minchars ->
        {:error, "String is shorter than minimum length of #{datainfo.minchars} characters"}

      Map.get(datainfo, :isUTF8, false) == false and
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
        Map.has_key?(datainfo, :maxbytes) and size > datainfo.maxbytes ->
          {:error, "Blob exceeds maximum size of #{datainfo.maxbytes} bytes"}

        Map.has_key?(datainfo, :minbytes) and size < datainfo.minbytes ->
          {:error, "Blob is smaller than minimum size of #{datainfo.minbytes} bytes"}

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
        Map.has_key?(datainfo, :maxlen) and size > datainfo.maxlen ->
          {:error, "Array exceeds maximum length of #{datainfo.maxlen} items"}

        Map.has_key?(datainfo, :minlen) and size < datainfo.minlen ->
          {:error, "Array is shorter than minimum length of #{datainfo.minlen} items"}

        true ->
          # Validate each element against the member type
          results = Enum.map(value, &validate_against_datainfo(datainfo.members, &1))
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
      expected_size = length(datainfo.members)

      if value_size != expected_size do
        {:error, "Tuple must have exactly #{expected_size} elements, got #{value_size}"}
      else
        # Validate each element against corresponding member type
        results =
          Enum.zip(value, datainfo.members)
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
      optional_members = Map.get(datainfo, :optional, [])
      required_keys = Map.keys(datainfo.members) -- optional_members

      # Check if all required keys are present
      missing_keys = Enum.filter(required_keys, fn key -> not Map.has_key?(value, key) end)

      if not Enum.empty?(missing_keys) do
        {:error, "Missing required fields: #{Enum.join(missing_keys, ", ")}"}
      else
        # Validate each present field against its type definition
        results =
          for {k, v} <- value, Map.has_key?(datainfo.members, k) do
            member_type = datainfo.members[k]
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
          expected_dimensions = length(datainfo.names)
          actual_dimensions = length(len)

          if expected_dimensions != actual_dimensions do
            {:error,
             "Matrix has wrong number of dimensions (expected #{expected_dimensions}, got #{actual_dimensions})"}
          else
            # Check dimension lengths against maxlen
            dim_errors =
              Enum.zip(len, datainfo.maxlen)
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
