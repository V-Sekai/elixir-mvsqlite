defmodule Exqlite.BenchmarkTest do
  use ExUnit.Case

  setup :create_conn!
  setup :create_and_drop_table

  test "benchmark workload A", %{conn: conn, table_name: table_name} do
    Benchee.run(
      %{
        "transaction" => fn ->
          Exqlite.transaction(conn, fn conn ->
            Enum.each(1..1, fn _ -> read_operation(conn, table_name) end)
            Enum.each(1..1, fn _ -> update_operation(conn, table_name) end)
          end)
        end
      },
      time: 60,
      warmup: 2,
      memory_time: 2
    )
  end

  test "benchmark workload B", %{conn: conn, table_name: table_name} do
    Benchee.run(
      %{
        "transaction" => fn ->
          Exqlite.transaction(conn, fn conn ->
            Enum.each(1..9, fn _ -> read_operation(conn, table_name) end)
            Enum.each(1..1, fn _ -> update_operation(conn, table_name) end)
          end)
        end
      },
      time: 60,
      warmup: 2,
      memory_time: 2
    )
  end

  defp read_operation(conn, table_name) do
    assert {:ok, res} =
             Exqlite.query(
               conn,
               "SELECT * FROM #{table_name};",
               []
             )

    res |> Table.to_rows() |> Enum.to_list()
  end

  defp update_operation(conn, table_name) do
    assert {:ok, _} =
             Exqlite.query(
               conn,
               "UPDATE #{table_name} SET y = 'd' WHERE x = 1;",
               []
             )
  end

  defp create_conn!(_) do
    opts = [database: "#{Temp.path!()}.db"]

    {:ok, pid} = start_supervised(Exqlite.child_spec(opts), %{id: :test})

    ref = Process.monitor(pid)

    [conn: pid, conn_ref: ref]
  end

  defp create_and_drop_table(context) do
    table_name = "tab_#{:os.system_time()}"
    Exqlite.query(context[:conn], "CREATE TABLE #{table_name} (x INT, y TEXT);", [])
    on_exit(fn -> drop_table(context) end)
    {:ok, Map.put(context, :table_name, table_name)}
  end

  defp drop_table(context) do
    if Process.alive?(context[:conn]) do
      Exqlite.query(context[:conn], "DROP TABLE #{context[:table_name]};", [])
    end

    :ok
  end
end
