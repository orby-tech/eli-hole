defmodule EliHoleWeb.TeleporterController do
  use EliHoleWeb, :controller

  alias EliHole.DNS.Teleporter

  def export(conn, _params) do
    {:ok, tar_binary} = Teleporter.export()

    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y-%m-%d_%H-%M-%S")

    filename = "elihole-teleporter_#{timestamp}.tar.gz"

    conn
    |> put_resp_content_type("application/gzip")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, tar_binary)
  end
end
