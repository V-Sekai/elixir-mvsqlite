defmodule Exqlite.Connection do
  @moduledoc """
  This module imlements connection details as defined in DBProtocol.

  ## Attributes

  - `db` - The sqlite3 database reference.
  - `path` - The path that was used to open.
  - `transaction_status` - The status of the connection. Can be `:idle` or `:transaction`.

  ## Unknowns

  - How are pooled connections going to work? Since sqlite3 doesn't allow for
    simultaneous access. We would need to check if the write ahead log is
    enabled on the database. We can't assume and set the WAL pragma because the
    database may be stored on a network volume which would cause potential
    issues.

  Notes:
    - we try to closely follow structure and naming convention of myxql.
    - sqlite thrives when there are many small conventions, so we may not implement
      some strategies employed by other adapters. See https://sqlite.org/np1queryprob.html
  """

  use DBConnection
  alias Exqlite.Error
  alias Exqlite.Pragma
  alias Exqlite.Query
  alias Exqlite.Result
  alias Exqlite.Sqlite3

  defstruct [
    :db,
    :path,
    :transaction_status,
    :status,
    :chunk_size
  ]

  @type t() :: %__MODULE__{
          db: Sqlite3.db(),
          path: String.t(),
          transaction_status: :idle | :transaction,
          status: :idle | :busy
        }

  @impl true
  @doc """
  Initializes the Ecto Exqlite adapter.

  For connection configurations we use the defaults that come with SQLite3, but
  we recommend which options to choose. We do not default to the recommended
  because we don't know what your environment is like.

  Allowed options:

    * `:database` - The path to the database. In memory is allowed. You can use
      `:memory` or `":memory:"` to designate that.
    * `:journal_mode` - Sets the journal mode for the sqlite connection. Can be
      one of the following `:delete`, `:truncate`, `:persist`, `:memory`,
      `:wal`, or `:off`. Defaults to `:delete`. It is recommended that you use
      `:wal` due to support for concurrent reads. Note: `:wal` does not mean
      concurrent writes.
    * `:temp_store` - Sets the storage used for temporary tables. Default is
      `:default`. Allowed values are `:default`, `:file`, `:memory`. It is
      recommended that you use `:memory` for storage.
    * `:synchronous` - Can be `:extra`, `:full`, `:normal`, or `:off`. Defaults
      to `:normal`.
    * `:foreign_keys` - Sets if foreign key checks should be enforced or not.
      Can be `:on` or `:off`. Default is `:on`.
    * `:cache_size` - Sets the cache size to be used for the connection. This is
      an odd setting as a positive value is the number of pages in memory to use
      and a negative value is the size in kilobytes to use. Default is `-2000`.
      It is recommended that you use `-64000`.
    * `:cache_spill` - The cache_spill pragma enables or disables the ability of
      the pager to spill dirty cache pages to the database file in the middle of
      a transaction. By default it is `:on`, and for most applications, it
      should remain so.
    * `:case_sensitive_like`
    * `:auto_vacuum` - Defaults to `:none`. Can be `:none`, `:full` or
      `:incremental`. Depending on the database size, `:incremental` may be
      beneficial.
    * `:locking_mode` - Defaults to `:normal`. Allowed values are `:normal` or
      `:exclusive`. See [sqlite documenation][1] for more information.
    * `:secure_delete` - Defaults to `:off`. If enabled, it will cause SQLite3
      to overwrite records that were deleted with zeros.
    * `:wal_auto_check_point` - Sets the write-ahead log auto-checkpoint
      interval. Default is `1000`. Setting the auto-checkpoint size to zero or a
      negative value turns auto-checkpointing off.
    * `:busy_timeout` - Sets the busy timeout in milliseconds for a connection.
      Default is `2000`.
    * `:chunk_size` - The chunk size for bulk fetching. Defaults to `50`.

  For more information about the options above, see [sqlite documenation][1]

  [1]: https://www.sqlite.org/pragma.html
  """
  def connect(options) do
    database = Keyword.get(options, :database)

    options =
      Keyword.put_new(
        options,
        :chunk_size,
        Application.get_env(:exqlite, :default_chunk_size, 50)
      )

    case database do
      nil ->
        {:error,
         %Error{
           message: """
           You must provide a :database to the database. \
           Example: connect(database: "./") or connect(database: :memory)\
           """
         }}

      :memory ->
        do_connect(":memory:", options)

      _ ->
        do_connect(database, options)
    end
  end

  @impl true
  def disconnect(_err, %__MODULE__{db: db}) do
    with :ok <- Sqlite3.close(db) do
      :ok
    else
      {:error, reason} -> {:error, %Error{message: reason}}
    end
  end

  @impl true
  def checkout(%__MODULE__{status: :idle} = state) do
    {:ok, %{state | status: :busy}}
  end

  def checkout(%__MODULE__{status: :busy} = state) do
    {:disconnect, %Error{message: "Database is busy"}, state}
  end

  @impl true
  def ping(state), do: {:ok, state}

  ##
  ## Handlers
  ##

  @impl true
  def handle_prepare(%Query{} = query, options, state) do
    with {:ok, query} <- prepare(query, options, state) do
      {:ok, query, state}
    end
  end

  @impl true
  def handle_execute(%Query{} = query, params, options, state) do
    with {:ok, query} <- prepare(query, options, state) do
      execute(:execute, query, params, state)
    end
  end

  @doc """
  Begin a transaction.

  For full info refer to sqlite docs: https://sqlite.org/lang_transaction.html

  Note: default transaction mode is DEFERRED.
  """
  @impl true
  def handle_begin(options, %{transaction_status: transaction_status} = state) do
    # TODO: This doesn't handle more than 2 levels of transactions.
    #
    # One possible solution would be to just track the number of open
    # transactions and use that for driving the transaction status being idle or
    # in a transaction.
    #
    # I do not know why the other official adapters do not track this and just
    # append level on the savepoint. Instead the rollbacks would just completely
    # revert the issues when it may be desirable to fix something while in the
    # transaction and then commit.
    case Keyword.get(options, :mode, :deferred) do
      :deferred when transaction_status == :idle ->
        handle_transaction(:begin, "BEGIN TRANSACTION", state)

      :transaction when transaction_status == :idle ->
        handle_transaction(:begin, "BEGIN TRANSACTION", state)

      :immediate when transaction_status == :idle ->
        handle_transaction(:begin, "BEGIN IMMEDIATE TRANSACTION", state)

      :exclusive when transaction_status == :idle ->
        handle_transaction(:begin, "BEGIN EXCLUSIVE TRANSACTION", state)

      mode
      when mode in [:deferred, :immediate, :exclusive, :savepoint] and
             transaction_status == :transaction ->
        handle_transaction(:begin, "SAVEPOINT exqlite_savepoint", state)
    end
  end

  @impl true
  def handle_commit(options, %{transaction_status: transaction_status} = state) do
    case Keyword.get(options, :mode, :deferred) do
      :savepoint when transaction_status == :transaction ->
        handle_transaction(
          :commit_savepoint,
          "RELEASE SAVEPOINT exqlite_savepoint",
          state
        )

      mode
      when mode in [:deferred, :immediate, :exclusive, :transaction] and
             transaction_status == :transaction ->
        handle_transaction(:commit, "COMMIT", state)
    end
  end

  @impl true
  def handle_rollback(options, %{transaction_status: transaction_status} = state) do
    case Keyword.get(options, :mode, :deferred) do
      :savepoint when transaction_status == :transaction ->
        with {:ok, _result, state} <-
               handle_transaction(
                 :rollback_savepoint,
                 "ROLLBACK TO SAVEPOINT exqlite_savepoint",
                 state
               ) do
          handle_transaction(
            :rollback_savepoint,
            "RELEASE SAVEPOINT exqlite_savepoint",
            state
          )
        end

      mode
      when mode in [:deferred, :immediate, :exclusive, :transaction] ->
        handle_transaction(:rollback, "ROLLBACK TRANSACTION", state)
    end
  end

  @doc """
  Close a query prepared by `c:handle_prepare/3` with the database. Return
  `{:ok, result, state}` on success and to continue,
  `{:error, exception, state}` to return an error and continue, or
  `{:disconnect, exception, state}` to return an error and disconnect.

  This callback is called in the client process.
  """
  @impl true
  def handle_close(query, _opts, state) do
    Sqlite3.release(state.db, query.ref)
    {:ok, nil, state}
  end

  @impl true
  def handle_declare(%Query{} = query, params, opts, state) do
    # We emulate cursor functionality by just using a prepared statement and
    # step through it. Thus we just return the query ref as the cursor.
    with {:ok, query} <- prepare_no_cache(query, opts, state),
         {:ok, query} <- bind_params(query, params, state) do
      {:ok, query, query.ref, state}
    end
  end

  @impl true
  def handle_deallocate(%Query{} = query, _cursor, _opts, state) do
    Sqlite3.release(state.db, query.ref)
    {:ok, nil, state}
  end

  @impl true
  def handle_fetch(%Query{statement: statement}, cursor, _opts, state) do
    case Sqlite3.step(state.db, cursor) do
      :done ->
        {
          :halt,
          %Result{
            rows: [],
            command: :fetch,
            num_rows: 0
          },
          state
        }

      {:row, row} ->
        {
          :cont,
          %Result{
            rows: [row],
            command: :fetch,
            num_rows: 1
          },
          state
        }

      :busy ->
        {:error, %Error{message: "Database busy", statement: statement}, state}

      {:error, reason} ->
        {:error, %Error{message: reason, statement: statement}, state}
    end
  end

  @impl true
  def handle_status(_opts, state) do
    {state.transaction_status, state}
  end

  ### ----------------------------------
  #     Internal functions and helpers
  ### ----------------------------------

  defp set_pragma(db, pragma_name, value) do
    Sqlite3.execute(db, "PRAGMA #{pragma_name} = #{value}")
  end

  defp get_pragma(db, pragma_name) do
    {:ok, statement} = Sqlite3.prepare(db, "PRAGMA #{pragma_name}")

    case Sqlite3.fetch_all(db, statement) do
      {:ok, [[value]]} -> {:ok, value}
      _ -> :error
    end
  end

  defp maybe_set_pragma(db, pragma_name, value) do
    case get_pragma(db, pragma_name) do
      {:ok, current} ->
        if current == value do
          :ok
        else
          set_pragma(db, pragma_name, value)
        end

      _ ->
        set_pragma(db, pragma_name, value)
    end
  end

  defp set_journal_mode(db, options) do
    maybe_set_pragma(db, "journal_mode", Pragma.journal_mode(options))
  end

  defp set_temp_store(db, options) do
    set_pragma(db, "temp_store", Pragma.temp_store(options))
  end

  defp set_synchronous(db, options) do
    set_pragma(db, "synchronous", Pragma.synchronous(options))
  end

  defp set_foreign_keys(db, options) do
    set_pragma(db, "foreign_keys", Pragma.foreign_keys(options))
  end

  defp set_cache_size(db, options) do
    maybe_set_pragma(db, "cache_size", Pragma.cache_size(options))
  end

  defp set_cache_spill(db, options) do
    set_pragma(db, "cache_spill", Pragma.cache_spill(options))
  end

  defp set_case_sensitive_like(db, options) do
    set_pragma(db, "case_sensitive_like", Pragma.case_sensitive_like(options))
  end

  defp set_auto_vacuum(db, options) do
    set_pragma(db, "auto_vacuum", Pragma.auto_vacuum(options))
  end

  defp set_locking_mode(db, options) do
    set_pragma(db, "locking_mode", Pragma.locking_mode(options))
  end

  defp set_secure_delete(db, options) do
    set_pragma(db, "secure_delete", Pragma.secure_delete(options))
  end

  defp set_wal_auto_check_point(db, options) do
    set_pragma(db, "wal_autocheckpoint", Pragma.wal_auto_check_point(options))
  end

  defp set_busy_timeout(db, options) do
    set_pragma(db, "busy_timeout", Pragma.busy_timeout(options))
  end

  defp do_connect(path, options) do
    with :ok <- mkdir_p(path),
         {:ok, db} <- Sqlite3.open(path),
         :ok <- set_journal_mode(db, options),
         :ok <- set_temp_store(db, options),
         :ok <- set_synchronous(db, options),
         :ok <- set_foreign_keys(db, options),
         :ok <- set_cache_size(db, options),
         :ok <- set_cache_spill(db, options),
         :ok <- set_auto_vacuum(db, options),
         :ok <- set_locking_mode(db, options),
         :ok <- set_secure_delete(db, options),
         :ok <- set_wal_auto_check_point(db, options),
         :ok <- set_case_sensitive_like(db, options),
         :ok <- set_busy_timeout(db, options) do
      state = %__MODULE__{
        db: db,
        path: path,
        transaction_status: :idle,
        status: :idle,
        chunk_size: Keyword.get(options, :chunk_size)
      }

      {:ok, state}
    else
      {:error, reason} ->
        {:error, %Exqlite.Error{message: reason}}
    end
  end

  def maybe_put_command(query, options) do
    case Keyword.get(options, :command) do
      nil -> query
      command -> %{query | command: command}
    end
  end

  # Attempt to retrieve the cached query, if it doesn't exist, we'll prepare one
  # and cache it for later.
  defp prepare(%Query{statement: statement} = query, options, state) do
    query = maybe_put_command(query, options)

    with {:ok, ref} <- Sqlite3.prepare(state.db, IO.iodata_to_binary(statement)),
         query <- %{query | ref: ref} do
      {:ok, query}
    else
      {:error, reason} ->
        {:error, %Error{message: reason, statement: statement}, state}
    end
  end

  # Prepare a query and do not cache it.
  defp prepare_no_cache(%Query{statement: statement} = query, options, state) do
    query = maybe_put_command(query, options)

    case Sqlite3.prepare(state.db, statement) do
      {:ok, ref} ->
        {:ok, %{query | ref: ref}}

      {:error, reason} ->
        {:error, %Error{message: reason, statement: statement}, state}
    end
  end

  @spec maybe_changes(Sqlite3.db(), Query.t()) :: integer() | nil
  defp maybe_changes(db, %Query{command: command})
       when command in [:update, :insert, :delete] do
    case Sqlite3.changes(db) do
      {:ok, total} -> total
      _ -> nil
    end
  end

  defp maybe_changes(_, _), do: nil

  # when we have an empty list of columns, that signifies that
  # there was no possible return tuple (e.g., update statement without RETURNING)
  # and in that case, we return nil to signify no possible result.
  defp maybe_rows([], []), do: nil
  defp maybe_rows(rows, _cols), do: rows

  defp execute(call, %Query{} = query, params, state) do
    with {:ok, query} <- bind_params(query, params, state),
         {:ok, columns} <- get_columns(query, state),
         {:ok, rows} <- get_rows(query, state),
         {:ok, transaction_status} <- Sqlite3.transaction_status(state.db),
         changes <- maybe_changes(state.db, query) do
      case query.command do
        command when command in [:delete, :insert, :update] ->
          {
            :ok,
            query,
            Result.new(
              command: call,
              num_rows: changes,
              rows: maybe_rows(rows, columns)
            ),
            %{state | transaction_status: transaction_status}
          }

        _ ->
          {
            :ok,
            query,
            Result.new(
              command: call,
              columns: columns,
              rows: rows,
              num_rows: Enum.count(rows)
            ),
            %{state | transaction_status: transaction_status}
          }
      end
    end
  end

  defp bind_params(%Query{ref: ref, statement: statement} = query, params, state)
       when ref != nil do
    case Sqlite3.bind(state.db, ref, params) do
      :ok ->
        {:ok, query}

      {:error, reason} ->
        {:error, %Error{message: reason, statement: statement}, state}
    end
  end

  defp get_columns(%Query{ref: ref, statement: statement}, state) do
    case Sqlite3.columns(state.db, ref) do
      {:ok, columns} ->
        {:ok, columns}

      {:error, reason} ->
        {:error, %Error{message: reason, statement: statement}, state}
    end
  end

  defp get_rows(%Query{ref: ref, statement: statement}, state) do
    case Sqlite3.fetch_all(state.db, ref, state.chunk_size) do
      {:ok, rows} ->
        {:ok, rows}

      {:error, reason} ->
        {:error, %Error{message: reason, statement: statement}, state}
    end
  end

  defp handle_transaction(call, statement, state) do
    with :ok <- Sqlite3.execute(state.db, statement),
         {:ok, transaction_status} <- Sqlite3.transaction_status(state.db) do
      result = %Result{
        command: call,
        rows: [],
        columns: [],
        num_rows: 0
      }

      {:ok, result, %{state | transaction_status: transaction_status}}
    else
      {:error, reason} ->
        {:disconnect, %Error{message: reason, statement: statement}, state}
    end
  end

  # SQLITE_OPEN_CREATE will create the DB file if not existing, but
  # will not create intermediary directories if they are missing.
  # So let's preemptively create the intermediate directories here
  # before trying to open the DB file.
  defp mkdir_p(":memory:"), do: :ok
  defp mkdir_p(path), do: File.mkdir_p(Path.dirname(path))
end
