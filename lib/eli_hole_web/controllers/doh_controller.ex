defmodule EliHoleWeb.DohController do
  @moduledoc """
  DNS-over-HTTPS endpoint (RFC 8484) at `/dns-query`.

  Accepts a wire-format DNS query and returns a wire-format response with the
  `application/dns-message` media type:

    * `GET  /dns-query?dns=<base64url>` — the query is an unpadded base64url
      string in the `dns` parameter (RFC 8484 §4.1).
    * `POST /dns-query` — the query is the raw request body
      (`content-type: application/dns-message`).

  Resolution, blocking, caching, and DNSSEC all flow through the shared
  `EliHole.DNS.Handler`, identical to plain-UDP and DoT queries. TLS is expected
  to be terminated by the Phoenix endpoint's HTTPS listener or a reverse proxy.
  """

  use EliHoleWeb, :controller

  alias EliHole.DNS.Handler

  @content_type "application/dns-message"
  # DNS messages over TCP/HTTP are length-prefixed by 16 bits → 65535 bytes max.
  @max_query_size 65_535

  def query(conn, %{"dns" => dns}) when is_binary(dns) do
    case Base.url_decode64(dns, padding: false) do
      {:ok, packet} when byte_size(packet) > 0 -> respond(conn, packet)
      {:ok, _empty} -> send_resp(conn, 400, "empty dns query")
      :error -> send_resp(conn, 400, "invalid dns parameter")
    end
  end

  def query(%Plug.Conn{method: "POST"} = conn, _params) do
    case read_query_body(conn) do
      {:ok, packet, conn} when byte_size(packet) > 0 -> respond(conn, packet)
      {:ok, _empty, conn} -> send_resp(conn, 400, "empty request body")
      {:error, conn} -> send_resp(conn, 413, "request body too large")
    end
  end

  def query(conn, _params), do: send_resp(conn, 400, "missing dns query")

  defp respond(conn, packet) do
    response = Handler.process(packet, client_display(conn), :doh, rate_key(conn))

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(200, response)
  end

  defp rate_key(%Plug.Conn{remote_ip: ip}) when not is_nil(ip), do: to_string(:inet.ntoa(ip))
  defp rate_key(_conn), do: nil

  defp read_query_body(conn) do
    case Plug.Conn.read_body(conn, length: @max_query_size) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, conn}
      {:error, _reason} -> {:error, conn}
    end
  end

  defp client_display(%Plug.Conn{remote_ip: ip}) when not is_nil(ip), do: "#{:inet.ntoa(ip)}"
  defp client_display(_conn), do: "doh"
end
