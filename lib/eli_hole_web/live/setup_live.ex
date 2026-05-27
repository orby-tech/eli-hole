defmodule EliHoleWeb.SetupLive do
  use EliHoleWeb, :live_view

  alias EliHole.Accounts
  alias EliHole.Accounts.AdminUser

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.setup_complete?() do
      {:ok, push_navigate(socket, to: "/login")}
    else
      changeset = AdminUser.registration_changeset(%AdminUser{}, %{})

      {:ok,
       socket
       |> assign(:form, to_form(changeset, as: :user))
       |> assign(:error, nil)}
    end
  end

  @impl true
  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.create_admin(params) do
      {:ok, _user} ->
        {:noreply, push_navigate(socket, to: "/login")}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :form, to_form(Map.put(changeset, :action, :insert), as: :user))}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %AdminUser{}
      |> AdminUser.registration_changeset(params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :user))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center">
      <div class="card bg-base-200 w-96 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl font-bold">EliHole Setup</h2>
          <p class="text-sm opacity-60">Create your admin account</p>

          <.form for={@form} id="setup-form" phx-submit="save" phx-change="validate" class="space-y-4">
            <.input field={@form[:username]} type="text" label="Username" autocomplete="username" />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
            />
            <button type="submit" class="btn btn-primary w-full">Create Admin</button>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
