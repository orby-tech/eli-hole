defmodule EliHole.Repo do
  use Ecto.Repo,
    otp_app: :eli_hole,
    adapter: Ecto.Adapters.Postgres
end
