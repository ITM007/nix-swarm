defmodule NixSwarm.TUI.Runtime do
  @moduledoc "Runtime integration helpers for the native Ratatui TUI."

  @doc "Suppress terminal logging for the duration of an interactive session."
  def with_terminal_logging_suppressed(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :none)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end

  @doc "Whether the ex_ratatui native library is available on disk."
  def supported?(app_dir_fun \\ &Application.app_dir/2) do
    app_dir_fun.(:ex_ratatui, "priv/native")
    |> File.dir?()
  end

  @doc "Describe how to run the TUI when its native library is unavailable."
  def support_error(app_dir_fun \\ &Application.app_dir/2) do
    native_dir = app_dir_fun.(:ex_ratatui, "priv/native")

    """
    the TUI requires a Mix or release runtime with the ex_ratatui native library available on disk

    run one of these instead:
      mix run -e 'NixSwarm.CLI.main(System.argv())' -- --target NODE
      #{NixSwarm.operator_launch()}

    expected ex_ratatui native directory:
      #{native_dir}
    """
    |> String.trim()
  end
end
