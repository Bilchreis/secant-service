defmodule SecantServiceWeb.DataBrowserLive.Index do
  use SecantServiceWeb, :live_view

  on_mount {SecantServiceWeb.LiveUserAuth, :live_user_optional}

  alias SecantService.SecNodes.SecNode

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:show_json_modal, false)
      |> assign(:json_content, "")
      |> assign(:json_title, "")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _, socket) do
    state_filter = parse_state_filter(params["state_filter"])

    case list_sec_nodes(params, state_filter, replace_invalid_params?: true) do
      {:ok, {sec_nodes, meta}} ->
        {:noreply,
         assign(socket, %{sec_nodes: sec_nodes, meta: meta, state_filter: state_filter})}

      {:error, meta} ->
        valid_path =
          AshPagify.Components.build_path(~p"/browse?state_filter=#{state_filter}", meta.params)

        {:noreply, push_navigate(socket, to: valid_path)}
    end
  end

  @impl true
  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply, push_patch(socket, to: ~p"/browse?state_filter=#{state}")}
  end

  @impl true
  def handle_event("toggle_favourite", %{"uuid" => uuid}, socket) do
    node = Enum.find(socket.assigns.sec_nodes, fn n -> n.uuid == uuid end)

    case Ash.update(node, %{}, action: :toggle_favourite) do
      {:ok, _updated} ->
        {:noreply, push_patch(socket, to: current_path(socket))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle favourite.")}
    end
  end

  @impl true
  def handle_event("trash_node", %{"uuid" => uuid}, socket) do
    node = Enum.find(socket.assigns.sec_nodes, fn n -> n.uuid == uuid end)

    case Ash.update(node, %{}, action: :trash) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Node moved to trash.")
         |> push_patch(to: current_path(socket))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Failed to trash node.")}
    end
  end

  @impl true
  def handle_event("restore_node", %{"uuid" => uuid}, socket) do
    node = Enum.find(socket.assigns.sec_nodes, fn n -> n.uuid == uuid end)

    case Ash.update(node, %{}, action: :restore) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Node restored.")
         |> push_patch(to: current_path(socket))}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Failed to restore node.")}
    end
  end

  @impl true
  def handle_event("open_json_modal", %{"uuid" => uuid}, socket) do
    # Find the node with the matching UUID
    node = Enum.find(socket.assigns.sec_nodes, fn n -> n.uuid == uuid end)

    # Format the JSON nicely
    formatted_json = Jason.encode!(node.describe_message, pretty: true)

    {:noreply,
     assign(socket,
       show_json_modal: true,
       json_content: formatted_json,
       json_title: "JSON Description: #{node.equipment_id} #{node.host}:#{}"
     )}
  end

  @impl true
  def handle_event("close_json_modal", _params, socket) do
    {:noreply, assign(socket, show_json_modal: false)}
  end

  @impl true
  def handle_event("trigger_cleanup", _params, socket) do
    result = AshOban.schedule_and_run_triggers({SecNode, :cleanup_old_nodes})

    total = Map.get(result, :success, 0) + Map.get(result, :failure, 0)

    flash =
      cond do
        Map.get(result, :failure, 0) > 0 ->
          {:error,
           "Cleanup finished with #{result.failure} failure(s) and #{result.success} success(es)."}

        total > 0 ->
          {:info, "Cleanup triggered successfully. #{total} node(s) moved to trash."}

        true ->
          {:info, "Cleanup triggered. No nodes matched for cleanup."}
      end

    {:noreply,
     socket
     |> put_flash(elem(flash, 0), elem(flash, 1))
     |> push_patch(to: current_path(socket))}
  end

  @impl true
  def handle_event("trigger_purge", _params, socket) do
    %{success: success, failure: failure} = SecNode.purge_all_trashed!()

    total = success + failure

    flash =
      cond do
        failure > 0 ->
          {:error, "Purge finished with #{failure} failure(s) and #{success} success(es)."}

        total > 0 ->
          {:info, "Purge completed. #{total} node(s) permanently deleted."}

        true ->
          {:info, "Purge triggered. No trashed nodes to delete."}
      end

    {:noreply,
     socket
     |> put_flash(elem(flash, 0), elem(flash, 1))
     |> push_patch(to: current_path(socket))}
  end

  defp list_sec_nodes(params, state_filter, opts) do
    query =
      case state_filter do
        :all ->
          SecNode

        :favourite ->
          SecNode |> Ash.Query.filter_input(%{favourite: %{eq: true}})

        filter_state ->
          SecNode |> Ash.Query.filter_input(%{state: %{eq: filter_state}})
      end

    AshPagify.validate_and_run(query, params, [action: :node_only] ++ opts)
  end

  defp parse_state_filter("archived"), do: :archived
  defp parse_state_filter("trashed"), do: :trashed
  defp parse_state_filter("active"), do: :active
  defp parse_state_filter("favourite"), do: :favourite
  defp parse_state_filter(_), do: :all

  defp current_path(socket) do
    state = socket.assigns[:state_filter] || :active
    ~p"/browse?state_filter=#{state}"
  end
end
