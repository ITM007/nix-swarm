defmodule NixSwarm.Deploy.Target do
  @moduledoc """
  Typed target identity and preflight classification values.
  """

  @type classification ::
          :new_nixos_host
          | :installed_inactive
          | :installed_unqueryable
          | :existing_in_sync
          | :existing_outdated
          | :draining
          | :maintenance
          | :unreachable
          | :incompatible

  @enforce_keys [:host, :configuration]
  defstruct [
    :host,
    :configuration,
    :node,
    :system,
    :classification,
    :blockers,
    :warnings,
    probes: %{}
  ]

  @type t :: %__MODULE__{
          host: String.t(),
          configuration: String.t(),
          node: String.t() | nil,
          system: String.t() | nil,
          classification: classification() | nil,
          blockers: [String.t()],
          warnings: [String.t()],
          probes: map()
        }
end
