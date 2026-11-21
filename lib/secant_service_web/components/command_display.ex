defmodule SecantServiceWeb.Components.CommandDisplay do
  use Phoenix.LiveComponent

  require Logger

  alias SecantService.NodeControl
  alias SecantServiceWeb.InFlight
  import SecantServiceWeb.CoreComponents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(
        %{
          class: class,
          host: host,
          port: port,
          module_name: module_name,
          command: command,
          location: location,
          id_str: id_str
        } = assigns,
        socket
      ) do
    if socket.assigns[:command] && socket.assigns.command.id == command.id do
      {:ok,
       socket
       |> assign(:class, class)
       |> assign(:variant, Map.get(assigns, :variant, :button))}
    else
      {:ok, init(socket, assigns, host, port, module_name, command, location, id_str, class)}
    end
  end

  def update(%{action: :clear_highlight} = _assigns, socket) do
    Logger.info("reset cmd success")
    socket = assign(socket, :command_success, nil)

    {:ok, socket}
  end

  def update(%{return_value: return_val} = assigns, socket) do
    if params = assigns[:params], do: InFlight.release(command_key(params))
    Logger.info("indicate command success")

    socket = assign(socket, :running, false)

    socket =
      case return_val do
        {:done, _module, command, data_report} ->
          send(self(), {:put_flash, [:info, "#{socket.assigns.module_name}:#{command} done"]})

          socket
          |> assign(:command_success, "done")
          |> assign(:last_result, {:ok, result_text(data_report)})

        {:error, :do, _specifier, error_class, error_text, _error_dict} ->
          send(
            self(),
            {:put_flash,
             [
               :error,
               "#{socket.assigns.module_name}:#{socket.assigns.command.name}: #{error_class} #{error_text}"
             ]}
          )

          socket
          |> assign(:command_success, "error")
          |> assign(:last_result, {:error, "#{error_class}: #{error_text}"})

        {:error, reason} when reason in [:disconnected, :uninitialized] ->
          send(
            self(),
            {:put_flash,
             [
               :error,
               "#{socket.assigns.module_name}:#{socket.assigns.command.name}: not sent, node not connected"
             ]}
          )

          socket
          |> assign(:command_success, "error")
          |> assign(:last_result, {:error, "Not sent: node not connected"})

        other ->
          send(self(), {:put_flash, [:error, inspect(other)]})

          socket
          |> assign(:command_success, "error")
          |> assign(:last_result, {:error, "No answer from node"})
      end

    send_update_after(__MODULE__, %{id: socket.assigns.id_str, action: :clear_highlight}, 1000)

    {:ok, socket}
  end

  def handle_event("validate_arg", params, socket) do
    Logger.info("Validating cmd arg #{params["command"]} with value #{params["value"]}")

    updated_arg_form =
      NodeControl.validate(
        params,
        socket.assigns.command.datainfo["argument"],
        socket.assigns.arg_form
      )

    {:noreply, assign(socket, :arg_form, updated_arg_form)}
  end

  # one run at a time per command: a second click while the node is still
  # working on the first must not send the command again (stop is exempt)
  def handle_event(
        "set_arg",
        _params,
        %{assigns: %{running: true, command: %{name: name}}} = socket
      )
      when name != "stop" do
    {:noreply, socket}
  end

  def handle_event("set_arg", params, socket) do
    params = Map.merge(params, target_params(socket))

    with {:ok, params} <- normalise_argument(params, socket),
         true <- claim_command(params) do
      run_command(params, socket)
    else
      {:invalid, arg_form} ->
        {:noreply, assign(socket, :arg_form, arg_form)}

      false ->
        # e.g. the same command is still running from the card or the inspector
        send(
          self(),
          {:put_flash,
           [:error, "#{socket.assigns.module_name}:#{params["command"]} is still running"]}
        )

        {:noreply, assign(socket, :last_result, {:error, "Already running"})}
    end
  end

  @impl true
  def handle_event("open_arg_modal", _params, socket) do
    {:noreply,
     assign(socket,
       show_arg_modal: true
     )}
  end

  @impl true
  def handle_event("close_arg_modal", _params, socket) do
    {:noreply, assign(socket, show_arg_modal: false)}
  end

  defp result_text([value | _]) when not is_nil(value),
    do: SecantService.Util.short_inspect(value, 160)

  defp result_text(_), do: nil

  # stop and go are the routine commands; everything else asks first.
  defp confirm_text(%{name: name}, _module_name) when name in ["stop", "go"], do: nil

  defp confirm_text(command, module_name),
    do: "Run '#{command.name}' on module '#{module_name}'?"

  defp tone(%{name: "stop"}),
    do: "border-st-error text-st-error hover:bg-st-error hover:text-base-100"

  defp tone(%{name: "go"}), do: "border-st-idle text-st-idle hover:bg-st-idle hover:text-base-100"
  defp tone(_), do: "border-line text-base-content hover:bg-base-300"

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:tone, tone(assigns.command))
      |> assign(:confirm, confirm_text(assigns.command, assigns.module_name))

    ~H"""
    <div class={[@variant == :row && "border-t border-line py-2 first:border-t-0", @class]}>
      <div class={[@variant == :row && "flex items-start gap-3"]}>
        <div :if={@variant == :row} class="min-w-0 flex-1">
          <div class="font-mono text-[13px] font-semibold">{@command.name}</div>
          <div :if={@command.description} class="text-xs text-muted">
            {@command.description}
          </div>
          <div :if={@has_arg} class="mt-0.5 font-mono text-xs text-muted">
            argument: {SecantServiceWeb.ValueFormat.type_label(@command.datainfo["argument"])}
          </div>
          <div
            :if={@last_result}
            class={[
              "mt-1 font-mono text-[11px] break-words",
              if(elem(@last_result, 0) == :ok, do: "text-muted", else: "text-st-error")
            ]}
          >
            → {elem(@last_result, 1) || "done"}
          </div>
        </div>

        <%= if @has_arg do %>
          <button
            type="button"
            onclick={"arg_modal_" <> to_string(@command.id) <> @location <> ".showModal()"}
            phx-click="open_arg_modal"
            phx-target={@myself}
            class={["cmd-btn btn btn-sm shrink-0 border bg-transparent font-mono", @tone]}
            mod-highlight={@command_success}
          >
            {if @variant == :row, do: "Run…", else: @command.name <> "…"}
          </button>
        <% else %>
          <.form
            for={@arg_form}
            id={"cmd-form:" <> @id_str}
            phx-submit="set_arg"
            phx-target={@myself}
            class="shrink-0"
          >
            <input type="hidden" name="port" value={Phoenix.HTML.Form.input_value(@arg_form, :port)} />
            <input type="hidden" name="host" value={Phoenix.HTML.Form.input_value(@arg_form, :host)} />
            <input
              type="hidden"
              name="location"
              value={Phoenix.HTML.Form.input_value(@arg_form, :location)}
            />
            <input
              type="hidden"
              name="module"
              value={Phoenix.HTML.Form.input_value(@arg_form, :module)}
            />
            <input type="hidden" name="command" value={@command.name} />
            <input type="hidden" name="value" value={nil} />
            <button
              type="submit"
              class={["cmd-btn btn btn-sm border bg-transparent font-mono", @tone]}
              mod-highlight={@command_success}
              data-confirm={@confirm}
              disabled={@running and @command.name != "stop"}
              aria-label={"#{@command.name} on #{@module_name}"}
            >
              <span :if={@running} class="loading loading-spinner loading-xs"></span>
              {if @variant == :row, do: "Run", else: @command.name}
            </button>
          </.form>
        <% end %>
      </div>

      <.modal
        :if={@has_arg}
        id={"arg_modal_" <> to_string(@command.id) <> @location}
        title={"#{@module_name}:#{@command.name}"}
        show={@show_arg_modal}
      >
        <div class="mb-2 text-sm text-muted">{@command.description}</div>
        <div class="mb-1 text-xs text-muted">Argument datatype</div>
        <pre class="max-h-[40vh] overflow-y-auto rounded border border-line bg-base-200 p-2 font-mono text-xs">{@arg_dtype}</pre>
        <.form
          for={@arg_form}
          id={"cmd-arg-form:" <> @id_str}
          phx-submit="set_arg"
          phx-change="validate_arg"
          phx-target={@myself}
          class="form-row mt-3 flex items-start gap-2"
        >
          <input type="hidden" name="port" value={Phoenix.HTML.Form.input_value(@arg_form, :port)} />
          <input type="hidden" name="host" value={Phoenix.HTML.Form.input_value(@arg_form, :host)} />
          <input
            type="hidden"
            name="location"
            value={Phoenix.HTML.Form.input_value(@arg_form, :location)}
          />
          <input
            type="hidden"
            name="module"
            value={Phoenix.HTML.Form.input_value(@arg_form, :module)}
          />
          <input type="hidden" name="command" value={@command.name} />
          <.input
            name="value"
            type="text"
            field={@arg_form[:value]}
            placeholder="argument as JSON"
            aria-label={"Argument for #{@command.name}"}
            phx-debounce="400"
            autocomplete="off"
            id={"form:" <> to_string(@command.id) <> @location}
            class="input input-sm w-full font-mono text-xs"
          />
          <button type="submit" class="btn btn-sm btn-primary shrink-0" disabled={@running}>
            <span :if={@running} class="loading loading-spinner loading-xs"></span>
            {if @running, do: "Running…", else: "Run"}
          </button>
        </.form>
        <div
          :if={@last_result}
          class={[
            "mt-2 font-mono text-xs break-words",
            if(elem(@last_result, 0) == :ok, do: "text-muted", else: "text-st-error")
          ]}
        >
          → {elem(@last_result, 1) || "done"}
        </div>
      </.modal>
    </div>
    """
  end

  defp init(socket, assigns, host, port, module_name, command, location, id_str, class) do
    has_arg = Map.has_key?(command.datainfo, "argument") and command.datainfo["argument"] != nil

    arg_dtype =
      cond do
        has_arg -> Jason.encode!(command.datainfo["argument"], pretty: true)
        true -> nil
      end

    node_id = {String.to_charlist(host), port}

    arg_form =
      to_form(%{
        "location" => "#{location}",
        "host" => to_string(host),
        "port" => Integer.to_string(port),
        "command" => command.name,
        "module" => module_name,
        "value" => nil
      })

    socket =
      socket
      |> assign(:command, command)
      |> assign(:module_name, module_name)
      |> assign(:node_id, node_id)
      |> assign(:host, host)
      |> assign(:port, port)
      |> assign(:class, class)
      |> assign(:location, location)
      |> assign(:show_arg_modal, false)
      |> assign(:arg_form, arg_form)
      |> assign(:return, nil)
      |> assign(:arg_dtype, arg_dtype)
      |> assign(:has_arg, has_arg)
      |> assign_new(:command_success, fn -> nil end)
      |> assign_new(:running, fn -> false end)
      |> assign(:id_str, id_str)
      |> assign(:variant, Map.get(assigns, :variant, :button))
      |> assign_new(:last_result, fn -> nil end)

    socket
  end

  # Which command to run comes from the component's own assigns, never from
  # the (client-editable) hidden form fields.
  defp target_params(socket) do
    %{
      "host" => to_string(socket.assigns.host),
      "port" => to_string(socket.assigns.port),
      "module" => socket.assigns.module_name,
      "command" => socket.assigns.command.name
    }
  end

  # stop must always go through, even while another stop is pending
  defp command_key(params),
    do: {:cmd, params["host"], params["port"], params["module"], params["command"]}

  defp claim_command(%{"command" => "stop"}), do: true
  defp claim_command(params), do: InFlight.claim(command_key(params))

  # Commands without an argument are sent unchanged. With an argument, the
  # typed value must pass validation and is sent as normalised JSON (so plain
  # text typed for a string argument is quoted).
  defp normalise_argument(params, %{assigns: %{has_arg: false}}), do: {:ok, params}

  defp normalise_argument(params, socket) do
    arg_form =
      NodeControl.validate(
        params,
        socket.assigns.command.datainfo["argument"],
        socket.assigns.arg_form
      )

    cond do
      params["value"] in [nil, ""] ->
        {:invalid, %{arg_form | errors: [value: {"Enter an argument", []}]}}

      arg_form.errors != [] ->
        {:invalid, arg_form}

      true ->
        value = arg_form.params["value"] |> Jason.decode!() |> Jason.encode!()
        {:ok, Map.put(params, "value", value)}
    end
  end

  defp run_command(params, socket) do
    Logger.info("Sending command #{params["command"]} with arg #{params["value"]}")

    pid = self()
    id = socket.assigns.id_str

    Task.start(fn ->
      return_val =
        try do
          NodeControl.execute_command(params)
        catch
          kind, reason -> {:exception, Exception.format_banner(kind, reason)}
        end

      Logger.info("NodeControl.execute_command returned: #{inspect(return_val)}")

      send(pid, {:in_flight_done, command_key(params)})
      send_update(pid, __MODULE__, %{id: id, return_value: return_val, params: params})
    end)

    {:noreply,
     socket
     |> assign(:command_success, "running")
     |> assign(:running, true)
     |> assign(:last_result, nil)}
  end
end
