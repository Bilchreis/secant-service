defmodule SecantService.ReadingsHypertableTest do
  @moduledoc "`readings` is a compressed hypertable, and data survives compression."
  use SecantService.DataCase, async: false

  alias SecantService.Repo
  alias SecantService.SecNodes
  alias SecantService.SecNodes.Reading.Storage

  # One reading per hour over the last three days, so the values span several
  # one-day chunks, with long runs of the same value.
  defp insert_readings(
         parameter,
         count \\ 72,
         value_fun \\ &if(rem(&1, 10) == 0, do: 21.5, else: 20.0)
       ) do
    now = DateTime.utc_now()

    rows =
      for i <- 1..count do
        Storage.to_row(value_fun.(i), parameter, DateTime.add(now, -i, :hour), %{"t" => 0})
      end

    %Ash.BulkResult{status: :success} = SecNodes.insert_readings(rows)
    rows
  end

  defp compress_all_chunks do
    %{rows: rows} = Repo.query!("SELECT compress_chunk(c) FROM show_chunks('readings') c")
    length(rows)
  end

  defp values_for(parameter) do
    parameter.id |> SecNodes.readings!() |> Enum.map(&{&1.timestamp, Storage.raw_value(&1)})
  end

  test "readings is a hypertable with compression segmented by parameter" do
    %{rows: rows} =
      Repo.query!("""
      SELECT h.hypertable_name, h.compression_enabled, s.segmentby
      FROM timescaledb_information.hypertables h
      JOIN timescaledb_information.hypertable_columnstore_settings s
        ON s.hypertable = format('%I.%I', h.hypertable_schema, h.hypertable_name)::regclass
      """)

    assert rows == [["readings", true, "parameter_id"]]

    %{rows: [[policies]]} =
      Repo.query!("""
      SELECT count(*) FROM timescaledb_information.jobs
      WHERE proc_name = 'policy_compression' AND hypertable_name = 'readings'
      """)

    assert policies == 1
  end

  test "values read back the same once compressed, scalars and spectra" do
    {_node, scalar} = node_with_parameter(node: [equipment_id: "sim_compress"])

    {_node, spectrum} =
      node_with_parameter(
        node: [equipment_id: "sim_spectrum"],
        datainfo: %{"type" => "array", "members" => %{"type" => "double"}}
      )

    rows = insert_readings(scalar)

    insert_readings(spectrum, 30, fn i -> for k <- 1..3600, do: :math.sin(k / 50 + i) * 1.0e-9 end)

    before = {values_for(scalar), values_for(spectrum)}
    assert length(elem(before, 0)) == length(rows)

    assert compress_all_chunks() > 1
    assert {values_for(scalar), values_for(spectrum)} == before

    # Late data can still be inserted into an already compressed chunk.
    insert_readings(scalar, 1)
    assert length(values_for(scalar)) == length(rows) + 1
  end

  test "the qualifier t is not stored twice" do
    {_node, parameter} = node_with_parameter(node: [equipment_id: "sim_qualifiers"])
    insert_readings(parameter, 1)
    assert [%{qualifiers: qualifiers}] = SecNodes.readings!(parameter.id)
    refute Map.has_key?(qualifiers, "t")
  end

  test "destroying a node removes its values from compressed chunks only" do
    {doomed_node, doomed} = node_with_parameter(node: [equipment_id: "sim_doomed"])
    {_kept_node, kept} = node_with_parameter(node: [equipment_id: "sim_kept"])
    insert_readings(doomed)
    kept_rows = insert_readings(kept)

    compress_all_chunks()
    Ash.destroy!(doomed_node)

    assert values_for(doomed) == []
    assert length(values_for(kept)) == length(kept_rows)
  end

  test "storage metrics still work on compressed data" do
    {_node, parameter} = node_with_parameter(node: [equipment_id: "sim_metrics"])
    rows = insert_readings(parameter)
    compress_all_chunks()

    loaded =
      parameter
      |> Ash.reload!()
      |> Ash.load!([:calculated_datapoint_count, :calculated_disk_size_bytes])

    assert loaded.calculated_datapoint_count == length(rows)
    assert loaded.calculated_disk_size_bytes > 0
  end
end
