defmodule EliHole.DNS.Teleporter do
  import Ecto.Query

  alias EliHole.Repo

  alias EliHole.DNS.{
    Adlists,
    BlocklistEntry,
    LocalDNS,
    LocalRecord,
    Provider,
    Providers,
    WhitelistEntry
  }

  require Logger

  @doc "Export EliHole config as tar.gz binary. Returns {:ok, binary} or {:error, reason}."
  def export do
    blocklist_exact =
      BlocklistEntry
      |> where(type: "exact")
      |> Repo.all()
      |> Enum.map(&entry_to_map/1)
      |> Jason.encode!()

    blocklist_wildcard =
      BlocklistEntry
      |> where(type: "wildcard")
      |> Repo.all()
      |> Enum.map(&entry_to_map/1)
      |> Jason.encode!()

    blocklist_regex =
      BlocklistEntry
      |> where(type: "regex")
      |> Repo.all()
      |> Enum.map(&entry_to_map/1)
      |> Jason.encode!()

    whitelist_exact =
      WhitelistEntry
      |> where(type: "exact")
      |> Repo.all()
      |> Enum.map(&entry_to_map/1)
      |> Jason.encode!()

    whitelist_wildcard =
      WhitelistEntry
      |> where(type: "wildcard")
      |> Repo.all()
      |> Enum.map(&entry_to_map/1)
      |> Jason.encode!()

    whitelist_regex =
      WhitelistEntry
      |> where(type: "regex")
      |> Repo.all()
      |> Enum.map(&entry_to_map/1)
      |> Jason.encode!()

    providers =
      Provider
      |> order_by(:position)
      |> Repo.all()
      |> Enum.map(&provider_to_map/1)
      |> Jason.encode!()

    local_dns =
      LocalRecord
      |> order_by(:domain)
      |> Repo.all()
      |> Enum.map(&local_record_to_map/1)
      |> Jason.encode!()

    files = [
      {"blocklist_exact.json", blocklist_exact},
      {"blocklist_wildcard.json", blocklist_wildcard},
      {"blocklist_regex.json", blocklist_regex},
      {"whitelist_exact.json", whitelist_exact},
      {"whitelist_wildcard.json", whitelist_wildcard},
      {"whitelist_regex.json", whitelist_regex},
      {"providers.json", providers},
      {"local_dns.json", local_dns}
    ]

    tar_files =
      Enum.map(files, fn {name, content} ->
        {String.to_charlist(name), content}
      end)

    case :erl_tar.create({:binary, []}, tar_files, [:compressed]) do
      {:ok, {_, tar_binary}} -> {:ok, tar_binary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Import from Pi-hole teleporter tar.gz binary.
  Returns {:ok, summary} with counts of imported items.
  """
  def import_pihole(tar_binary) when is_binary(tar_binary) do
    with {:ok, files} <- extract_tar(tar_binary) do
      summary = %{blocklist: 0, whitelist: 0, providers: 0, gravity: 0, local_dns: 0, skipped: []}

      summary = import_pihole_blacklist(files, summary)
      summary = import_pihole_whitelist(files, summary)
      summary = import_pihole_providers(files, summary)
      summary = import_pihole_gravity(files, summary)
      summary = import_pihole_local_dns(files, summary)
      summary = note_skipped(files, summary)

      {:ok, summary}
    end
  end

  @doc """
  Import from EliHole's own tar.gz export.
  Returns {:ok, summary} with counts.
  """
  def import_elihole(tar_binary) when is_binary(tar_binary) do
    with {:ok, files} <- extract_tar(tar_binary) do
      summary = %{blocklist: 0, whitelist: 0, providers: 0, local_dns: 0}

      summary = import_elihole_blocklist(files, "blocklist_exact.json", "exact", summary)
      summary = import_elihole_blocklist(files, "blocklist_wildcard.json", "wildcard", summary)
      summary = import_elihole_blocklist(files, "blocklist_regex.json", "regex", summary)
      summary = import_elihole_whitelist(files, "whitelist_exact.json", "exact", summary)
      summary = import_elihole_whitelist(files, "whitelist_wildcard.json", "wildcard", summary)
      summary = import_elihole_whitelist(files, "whitelist_regex.json", "regex", summary)
      summary = import_elihole_providers(files, summary)
      summary = import_elihole_local_dns(files, summary)

      {:ok, summary}
    end
  end

  @doc "Detect if tar.gz is Pi-hole or EliHole format."
  def detect_format(tar_binary) do
    case extract_tar(tar_binary) do
      {:ok, files} ->
        names = Map.keys(files)

        cond do
          "blacklist.exact.json" in names or "setupVars.conf" in names ->
            :pihole

          "blocklist_exact.json" in names or "providers.json" in names or
              "local_dns.json" in names ->
            :elihole

          true ->
            :unknown
        end

      {:error, _} ->
        :unknown
    end
  end

  # --- Private ---

  defp extract_tar(tar_binary) do
    case :erl_tar.extract({:binary, tar_binary}, [:memory, :compressed]) do
      {:ok, file_list} ->
        files =
          Map.new(file_list, fn {name, content} ->
            {List.to_string(name), content}
          end)

        {:ok, files}

      {:error, reason} ->
        {:error, "Failed to extract tar: #{inspect(reason)}"}
    end
  end

  defp import_pihole_blacklist(files, summary) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    exact_entries =
      files
      |> Map.get("blacklist.exact.json", "[]")
      |> Jason.decode!()
      |> Enum.filter(&(&1["enabled"] == 1))
      |> Enum.map(fn item ->
        %{
          domain: String.downcase(item["domain"]),
          type: "exact",
          source: "pihole_import",
          enabled: true,
          comment: item["comment"],
          inserted_at: now,
          updated_at: now
        }
      end)

    regex_entries =
      files
      |> Map.get("blacklist.regex.json", "[]")
      |> Jason.decode!()
      |> Enum.filter(&(&1["enabled"] == 1))
      |> Enum.map(fn item ->
        %{
          domain: item["domain"],
          type: "regex",
          source: "pihole_import",
          enabled: true,
          comment: item["comment"],
          inserted_at: now,
          updated_at: now
        }
      end)

    all_entries = exact_entries ++ regex_entries

    {count, _} =
      Repo.insert_all(BlocklistEntry, all_entries,
        on_conflict: :nothing,
        conflict_target: [:domain, :type]
      )

    %{summary | blocklist: count}
  end

  defp import_pihole_whitelist(files, summary) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    exact_entries =
      files
      |> Map.get("whitelist.exact.json", "[]")
      |> Jason.decode!()
      |> Enum.filter(&(&1["enabled"] == 1))
      |> Enum.map(fn item ->
        %{
          domain: String.downcase(item["domain"]),
          type: "exact",
          source: "pihole_import",
          enabled: true,
          comment: item["comment"],
          inserted_at: now,
          updated_at: now
        }
      end)

    regex_entries =
      files
      |> Map.get("whitelist.regex.json", "[]")
      |> Jason.decode!()
      |> Enum.filter(&(&1["enabled"] == 1))
      |> Enum.map(fn item ->
        %{
          domain: item["domain"],
          type: "regex",
          source: "pihole_import",
          enabled: true,
          comment: item["comment"],
          inserted_at: now,
          updated_at: now
        }
      end)

    all_entries = exact_entries ++ regex_entries

    {count, _} =
      Repo.insert_all(WhitelistEntry, all_entries,
        on_conflict: :nothing,
        conflict_target: [:domain, :type]
      )

    %{summary | whitelist: count}
  end

  defp import_pihole_providers(files, summary) do
    case Map.get(files, "setupVars.conf") do
      nil ->
        summary

      content ->
        dns_entries =
          content
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, "PIHOLE_DNS_"))
          |> Enum.map(fn line ->
            [_key, value] = String.split(line, "=", parts: 2)
            String.trim(value)
          end)

        existing =
          Providers.list_all()
          |> MapSet.new(fn p -> {p.ip, p.port} end)

        count =
          dns_entries
          |> Enum.with_index(1)
          |> Enum.reduce(0, fn {ip_str, idx}, acc ->
            if MapSet.member?(existing, {ip_str, 53}) do
              acc
            else
              case Providers.create(%{
                     "name" => "Pi-hole DNS #{idx}",
                     "ip" => ip_str,
                     "port" => 53
                   }) do
                {:ok, _} -> acc + 1
                {:error, _} -> acc
              end
            end
          end)

        %{summary | providers: count}
    end
  end

  defp import_pihole_gravity(files, summary) do
    case Map.get(files, "adlist.json") do
      nil ->
        summary

      content ->
        adlists =
          content
          |> Jason.decode!()
          |> Enum.filter(&(&1["enabled"] == 1))

        count =
          Enum.reduce(adlists, 0, fn item, acc ->
            case Adlists.create(%{
                   "address" => item["address"],
                   "comment" => item["comment"] || "Pi-hole import"
                 }) do
              {:ok, _} -> acc + 1
              {:error, _} -> acc
            end
          end)

        %{summary | gravity: count}
    end
  end

  defp note_skipped(files, summary) do
    skipped =
      []
      |> maybe_skip(files, "client.json", "clients")
      |> maybe_skip(files, "group.json", "groups")

    %{summary | skipped: skipped}
  end

  defp maybe_skip(acc, files, filename, label) do
    case Map.get(files, filename) do
      nil ->
        acc

      content ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) and list != [] ->
            [label | acc]

          _ ->
            if String.trim(content) != "", do: [label | acc], else: acc
        end
    end
  end

  defp import_elihole_blocklist(files, filename, type, summary) do
    case Map.get(files, filename) do
      nil ->
        summary

      content ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        entries =
          content
          |> Jason.decode!()
          |> Enum.map(fn item ->
            %{
              domain: item["domain"],
              type: type,
              source: item["source"] || "elihole_import",
              enabled: item["enabled"],
              comment: item["comment"],
              inserted_at: now,
              updated_at: now
            }
          end)

        {count, _} =
          Repo.insert_all(BlocklistEntry, entries,
            on_conflict: :nothing,
            conflict_target: [:domain, :type]
          )

        %{summary | blocklist: summary.blocklist + count}
    end
  end

  defp import_elihole_whitelist(files, filename, type, summary) do
    case Map.get(files, filename) do
      nil ->
        summary

      content ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        entries =
          content
          |> Jason.decode!()
          |> Enum.map(fn item ->
            %{
              domain: item["domain"],
              type: type,
              source: item["source"] || "elihole_import",
              enabled: item["enabled"] != false,
              comment: item["comment"],
              inserted_at: now,
              updated_at: now
            }
          end)

        {count, _} =
          Repo.insert_all(WhitelistEntry, entries,
            on_conflict: :nothing,
            conflict_target: [:domain, :type]
          )

        %{summary | whitelist: summary.whitelist + count}
    end
  end

  defp import_elihole_providers(files, summary) do
    case Map.get(files, "providers.json") do
      nil ->
        summary

      content ->
        providers = Jason.decode!(content)

        count =
          Enum.reduce(providers, 0, fn p, acc ->
            attrs = %{
              "name" => p["name"],
              "ip" => p["ip"],
              "port" => p["port"],
              "enabled" => p["enabled"]
            }

            case Providers.create(attrs) do
              {:ok, _} -> acc + 1
              {:error, _} -> acc
            end
          end)

        %{summary | providers: count}
    end
  end

  defp import_pihole_local_dns(files, summary) do
    case Map.get(files, "custom.list") do
      nil ->
        summary

      content ->
        {:ok, count} = LocalDNS.import_custom_list(content)
        Map.put(summary, :local_dns, count)
    end
  end

  defp import_elihole_local_dns(files, summary) do
    case Map.get(files, "local_dns.json") do
      nil ->
        summary

      content ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        entries =
          content
          |> Jason.decode!()
          |> Enum.map(fn item ->
            %{
              domain: item["domain"],
              record_type: item["record_type"],
              target: item["target"],
              enabled: item["enabled"],
              comment: item["comment"],
              inserted_at: now,
              updated_at: now
            }
          end)

        {count, _} =
          Repo.insert_all(LocalRecord, entries,
            on_conflict: :nothing,
            conflict_target: [:domain, :record_type]
          )

        LocalDNS.flush_cache()
        %{summary | local_dns: count}
    end
  end

  defp entry_to_map(%BlocklistEntry{} = e), do: do_entry_to_map(e)
  defp entry_to_map(%WhitelistEntry{} = e), do: do_entry_to_map(e)

  defp do_entry_to_map(e) do
    %{
      domain: e.domain,
      type: e.type,
      source: e.source,
      enabled: e.enabled,
      comment: e.comment
    }
  end

  defp provider_to_map(%Provider{} = p) do
    %{
      name: p.name,
      ip: p.ip,
      port: p.port,
      enabled: p.enabled,
      position: p.position
    }
  end

  defp local_record_to_map(%LocalRecord{} = r) do
    %{
      domain: r.domain,
      record_type: r.record_type,
      target: r.target,
      enabled: r.enabled,
      comment: r.comment
    }
  end
end
