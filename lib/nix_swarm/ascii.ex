defmodule NixSwarm.Ascii do
  @moduledoc false

  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Style

  def cluster_tree(%{configured_nodes: configured_nodes, live_nodes: live_nodes}, %{
        placements: placements
      }) do
    live_nodes = MapSet.new(live_nodes)

    owned_by_node =
      placements
      |> Enum.flat_map(fn {service, slots} ->
        Enum.map(slots, fn slot ->
          Map.put(slot, :service, service)
        end)
      end)
      |> Enum.group_by(& &1.owner)

    configured_nodes
    |> Enum.sort_by(&Atom.to_string/1)
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      last_node? = index == length(configured_nodes) - 1
      connector = tree_connector(last_node?)
      continuation = tree_continuation(last_node?)
      status = if MapSet.member?(live_nodes, node), do: "[up]", else: "[down]"
      head = "#{connector} #{node} #{status}"

      slot_lines =
        case Map.get(owned_by_node, node, []) |> Enum.sort_by(&{&1.service, &1.slot}) do
          [] ->
            ["#{continuation}#{tree_connector(true)} idle"]

          slots ->
            slots
            |> Enum.with_index()
            |> Enum.map(fn {slot, slot_index} ->
              "#{continuation}#{tree_connector(slot_index == length(slots) - 1)} #{slot.service} slot #{slot.slot} (#{slot.unit})"
            end)
        end

      [head | slot_lines]
    end)
    |> Enum.join("\n")
  end

  def cluster_flow(
        target,
        %{queried_node: queried_node, live_nodes: live_nodes, placements: placements},
        selected_service
      ) do
    slots =
      selected_service
      |> select_service(placements)
      |> Enum.sort_by(& &1.slot)

    slot_lines =
      case slots do
        [] ->
          ["  (no service slots available)"]

        _ ->
          Enum.map(slots, fn slot ->
            "  #{selected_service_label(selected_service, slot)} -> #{slot.owner || "unplaced"} -> #{slot.unit}"
          end)
      end

    [
      "operator -> swarm tui -> target #{target}",
      "                            |",
      "                            v",
      "                 queried #{queried_node}",
      "                            |",
      "    +-- live nodes: #{format_nodes(live_nodes)}",
      "    |",
      "    +-- service ownership",
      Enum.join(slot_lines, "\n")
    ]
    |> Enum.join("\n")
  end

  defp select_service(nil, placements) do
    case placements |> Enum.sort_by(fn {service, _slots} -> service end) do
      [{service, slots} | _] -> Enum.map(slots, &Map.put(&1, :service, service))
      [] -> []
    end
  end

  defp select_service(service, placements) do
    placements
    |> Map.get(service, [])
    |> Enum.map(&Map.put(&1, :service, service))
  end

  defp selected_service_label(nil, slot), do: "#{slot.service || "service"} slot #{slot.slot}"
  defp selected_service_label(service, slot), do: "#{service} slot #{slot.slot}"

  defp format_nodes(nodes) do
    nodes
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp tree_connector(true), do: "`--"
  defp tree_connector(false), do: "|--"
  defp tree_continuation(true), do: "   "
  defp tree_continuation(false), do: "|  "

  def cluster_map(status, tick) do
    step = rem(div(tick * 5, 24), 8)
    ingress_idx = if step < 4, do: step, else: nil
    fanout_progress = if step >= 4, do: step - 4, else: nil

    traffic =
      Enum.map(0..3, fn i ->
        char =
          if i == ingress_idx do
            Span.new("v", style: %Style{fg: :magenta, modifiers: [:bold]})
          else
            Span.new("|", style: %Style{fg: :dark_gray})
          end

        Line.new([char])
      end)

    header =
      [
        Line.new([
          Span.new("[ EXTERNAL TRAFFIC ]", style: %Style{fg: :cyan, modifiers: [:bold]})
        ])
      ] ++
        traffic ++
        [
          Line.new([
            Span.new(
              "====================== [ SWARM NETWORK ] ======================",
              style: %Style{fg: :blue, modifiers: [:bold]}
            )
          ])
        ]

    nodes = Enum.sort_by(status.nodes, fn {n, _} -> n end)
    chunks = Enum.chunk_every(nodes, 3)

    body =
      Enum.flat_map(chunks, fn chunk ->
        render_node_chunk(chunk, fanout_progress)
      end)

    header ++ [Line.new([])] ++ body
  end

  defp render_node_chunk(nodes, fanout_progress) do
    contents = Enum.map(nodes, &build_node_content/1)
    box_width = node_box_width(contents)
    max_lines = contents |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    boxes = Enum.map(contents, &format_node_box(&1, max_lines, box_width))
    fanout = fanout_lines(length(nodes), fanout_progress, box_width)

    transposed =
      boxes
      |> Enum.zip()
      |> Enum.map(fn tuple ->
        Tuple.to_list(tuple)
        |> Enum.intersperse([Span.new("    ")])
        |> List.flatten()
        |> Line.new()
      end)

    fanout ++ transposed ++ [Line.new([])]
  end

  defp fanout_lines(node_count, fanout_progress, box_width) do
    width = total_chunk_width(node_count, box_width)
    centers = node_centers(node_count, box_width)
    source = div(width - 1, 2)

    branch_positions =
      Enum.reduce(centers, %{source => {"+", source_color(fanout_progress)}}, fn center, acc ->
        acc
        |> Map.put(center, {"+", :dark_gray})
        |> add_horizontal_path(source, center)
      end)

    branch_highlights =
      if fanout_progress == 1 do
        Enum.reduce(centers, %{}, fn center, acc ->
          Map.put(acc, midpoint(source, center), {"o", :magenta})
        end)
      else
        %{}
      end

    vertical_positions =
      Enum.reduce(centers, %{}, fn center, acc ->
        color = if fanout_progress == 2, do: :magenta, else: :dark_gray
        char = if fanout_progress == 2, do: "o", else: "|"
        Map.put(acc, center, {char, color})
      end)

    arrow_positions =
      Enum.reduce(centers, %{}, fn center, acc ->
        color = if fanout_progress == 3, do: :magenta, else: :dark_gray
        Map.put(acc, center, {"v", color})
      end)

    [
      styled_line(width, Map.merge(branch_positions, branch_highlights)),
      styled_line(width, vertical_positions),
      styled_line(width, arrow_positions)
    ]
  end

  defp add_horizontal_path(acc, source, center) when source == center, do: acc

  defp add_horizontal_path(acc, source, center) do
    range =
      if center < source do
        (center + 1)..(source - 1)
      else
        (source + 1)..(center - 1)
      end

    Enum.reduce(range, acc, fn position, current ->
      Map.put(current, position, {"-", :dark_gray})
    end)
  end

  defp midpoint(a, b), do: div(a + b, 2)

  defp total_chunk_width(node_count, box_width),
    do: node_count * box_width + max(node_count - 1, 0) * 4

  defp node_centers(node_count, box_width) do
    Enum.map(0..(node_count - 1), fn index ->
      index * (box_width + 4) + div(box_width - 1, 2)
    end)
  end

  defp source_color(0), do: :magenta
  defp source_color(_progress), do: :dark_gray

  defp styled_line(width, positions) do
    0..(width - 1)
    |> Enum.map(fn index ->
      case Map.get(positions, index) do
        nil ->
          Span.new(" ")

        {char, color} ->
          Span.new(char,
            style: %Style{fg: color, modifiers: if(color == :magenta, do: [:bold], else: [])}
          )
      end
    end)
    |> Line.new()
  end

  defp build_node_content({node_name, node_status}) do
    name_str = Atom.to_string(node_name)
    hostname = String.split(name_str, "@") |> List.last()

    ips = Map.get(node_status, :network_info, %{}) |> Map.get(:ips, [])
    ports = Map.get(node_status, :network_info, %{}) |> Map.get(:ports, [])

    ips_str = Enum.join(ips, ", ")

    services = Map.get(node_status, :services, [])

    services_lines =
      services
      |> Enum.flat_map(fn s ->
        s.units
        |> Enum.filter(&(&1.status == :running))
        |> Enum.map(fn u ->
          color = if u.status == :running, do: :green, else: :red
          status_char = if u.status == :running, do: "R", else: "S"
          service_ports = format_service_ports(Map.get(s, :ports, []))

          [
            Span.new("  - #{s.name}@#{u.slot} ["),
            Span.new(status_char, style: %Style{fg: color, modifiers: [:bold]}),
            Span.new("]"),
            Span.new(service_ports, style: %Style{fg: :yellow})
          ]
        end)
      end)

    error_lines =
      services
      |> Enum.flat_map(fn service ->
        desired_state = Map.get(service, :desired_state, :running)

        service.units
        |> Enum.filter(fn unit ->
          desired_state != :stopped and
            Map.get(unit, :owner) == node_name and
            Map.get(unit, :status) != :running
        end)
        |> Enum.map(fn unit ->
          [
            Span.new("  ! #{service.name}@#{unit.slot} "),
            Span.new(to_string(Map.get(unit, :status, :unknown)),
              style: %Style{fg: :red, modifiers: [:bold]}
            )
          ]
        end)
      end)

    service_section =
      if services_lines == [] do
        [[Span.new("  (no active services)", style: %Style{fg: :dark_gray})]]
      else
        services_lines
      end

    error_section =
      case error_lines do
        [] ->
          []

        _ ->
          [
            [],
            [Span.new(" Errors:", style: %Style{fg: :red, modifiers: [:bold]})]
          ] ++ error_lines
      end

    [
      [Span.new(" hostname: "), Span.new(truncate(hostname, 17), style: %Style{fg: :dark_gray})],
      [Span.new(" node: "), Span.new(truncate(name_str, 21), style: %Style{fg: :cyan})],
      [Span.new(" IPs: "), Span.new(truncate(ips_str, 22), style: %Style{fg: :green})]
    ] ++
      ports_lines(ports) ++
      [
        [],
        [Span.new(" Services:")]
      ] ++ service_section ++ error_section
  end

  defp ports_lines([]), do: [[Span.new(" Ports: "), Span.new("-", style: %Style{fg: :yellow})]]

  defp ports_lines(ports) do
    ports
    |> Enum.chunk_every(5)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      label = if index == 0, do: " Ports: ", else: "        "

      [
        Span.new(label),
        Span.new(Enum.map_join(chunk, ", ", &to_string/1), style: %Style{fg: :yellow})
      ]
    end)
  end

  defp format_service_ports([]), do: ""
  defp format_service_ports(ports), do: " " <> Enum.map_join(ports, ", ", &to_string/1)

  defp span_length(spans) do
    Enum.reduce(spans, 0, fn
      %Span{content: text}, acc -> acc + String.length(text)
      text, acc when is_binary(text) -> acc + String.length(text)
    end)
  end

  defp node_box_width(contents) do
    longest_line =
      contents
      |> Enum.flat_map(& &1)
      |> Enum.map(&span_length/1)
      |> Enum.max(fn -> 0 end)

    max(28, longest_line + 3)
  end

  defp format_node_box(content, max_lines, box_width) do
    pad = max_lines - length(content)
    padded_content = content ++ List.duplicate([], pad)

    top = [
      Span.new("+" <> String.duplicate("-", box_width - 2) <> "+", style: %Style{fg: :dark_gray})
    ]

    bottom = top

    formatted_content =
      Enum.map(padded_content, fn line ->
        line_pad = box_width - 3 - span_length(line)
        line_pad = max(line_pad, 0)

        [Span.new("|", style: %Style{fg: :dark_gray})] ++
          line ++
          [Span.new(String.duplicate(" ", line_pad) <> " |", style: %Style{fg: :dark_gray})]
      end)

    [top] ++ formatted_content ++ [bottom]
  end

  defp truncate(str, max_len) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len - 3) <> "..."
    else
      str
    end
  end
end
