defmodule SecantService.SecNodes.ParameterValueHypertableTest do
  use SecantService.DataCase, async: false

  alias SecantService.Repo
  alias SecantService.SecNodes.{Module, Parameter, ParameterValueDouble, SecNode}

  @value_tables ~w(
    parameter_values_array_bool
    parameter_values_array_double
    parameter_values_array_int
    parameter_values_array_string
    parameter_values_bool
    parameter_values_double
    parameter_values_int
    parameter_values_json
    parameter_values_string
  )

  defp create_double_parameter(equipment_id) do
    node =
      SecNode
      |> Ash.Changeset.for_create(:create, %{
        uuid: Ecto.UUID.generate(),
        equipment_id: equipment_id,
        host: "localhost",
        port: 10_800
      })
      |> Ash.create!()

    module =
      Module
      |> Ash.Changeset.for_create(:create, %{name: "T", sec_node_id: node.uuid})
      |> Ash.create!()

    parameter =
      Parameter
      |> Ash.Changeset.for_create(:create, %{
        name: "value",
        datainfo: %{"type" => "double"},
        module_id: module.id
      })
      |> Ash.create!()

    {node, parameter}
  end

  # One reading per hour over the last three days, so the values span several
  # one-day chunks, with long runs of the same value.
  defp insert_readings(parameter, count \\ 72) do
    now = DateTime.utc_now()

    readings =
      for i <- 1..count do
        %{
          parameter_id: parameter.id,
          value: Decimal.new(if(rem(i, 10) == 0, do: "21.5", else: "20.0")),
          timestamp: DateTime.add(now, -i, :hour),
          qualifiers: %{"t" => DateTime.to_unix(now) - i * 3600}
        }
      end

    %Ash.BulkResult{status: :success} =
      Ash.bulk_create(readings, ParameterValueDouble, :bulk_create, return_errors?: true)

    readings
  end

  defp compress_all_chunks(table) do
    %{rows: rows} = Repo.query!("SELECT compress_chunk(c) FROM show_chunks('#{table}') c")
    length(rows)
  end

  defp values_for(parameter) do
    ParameterValueDouble
    |> Ash.Query.for_read(:for_parameter, %{parameter_id: parameter.id})
    |> Ash.read!()
  end

  test "every value table is a hypertable with compression segmented by parameter" do
    %{rows: rows} =
      Repo.query!("""
      SELECT h.hypertable_name, h.compression_enabled, s.segmentby
      FROM timescaledb_information.hypertables h
      JOIN timescaledb_information.hypertable_columnstore_settings s
        ON s.hypertable = format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass
      ORDER BY 1
      """)

    assert rows == Enum.map(@value_tables, &[&1, true, "parameter_id"])

    %{rows: [[policies]]} =
      Repo.query!("""
      SELECT count(*) FROM timescaledb_information.jobs
      WHERE proc_name = 'policy_compression'
      """)

    assert policies == length(@value_tables)
  end

  test "values written through Ash read back the same once compressed" do
    {_node, parameter} = create_double_parameter("sim_compress")
    readings = insert_readings(parameter)

    before = values_for(parameter)
    assert length(before) == length(readings)

    assert compress_all_chunks("parameter_values_double") > 1

    after_compression = values_for(parameter)

    assert Enum.map(after_compression, &{&1.timestamp, &1.value}) ==
             Enum.map(before, &{&1.timestamp, &1.value})

    # Late data can still be inserted into an already compressed chunk.
    insert_readings(parameter, 1)
    assert length(values_for(parameter)) == length(readings) + 1
  end

  test "destroying a node removes its values from compressed chunks only" do
    {doomed_node, doomed} = create_double_parameter("sim_doomed")
    {_kept_node, kept} = create_double_parameter("sim_kept")
    insert_readings(doomed)
    kept_readings = insert_readings(kept)

    compress_all_chunks("parameter_values_double")

    :ok = Ash.destroy(doomed_node)

    assert values_for(doomed) == []
    assert length(values_for(kept)) == length(kept_readings)
  end

  test "storage metrics still work on compressed data" do
    {_node, parameter} = create_double_parameter("sim_metrics")
    readings = insert_readings(parameter)
    compress_all_chunks("parameter_values_double")

    loaded =
      parameter
      |> Ash.reload!()
      |> Ash.load!([:calculated_datapoint_count, :calculated_disk_size_bytes])

    assert loaded.calculated_datapoint_count == length(readings)
    assert loaded.calculated_disk_size_bytes > 0
  end
end
