defmodule EliHoleWeb.LoginLive do
  use EliHoleWeb, :live_view

  alias EliHole.Accounts

  @impl true
  def mount(_params, _session, socket) do
    unless Accounts.setup_complete?() do
      {:ok, push_navigate(socket, to: "/setup")}
    else
      {:ok,
       assign(socket,
         form: to_form(%{"username" => "", "password" => ""}, as: :user),
         error: nil
       )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center">
      <div class="card bg-base-200 w-96 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl font-bold">EliHole Login</h2>

          <div :if={@flash[:error]} class="alert alert-error text-sm">
            {@flash[:error]}
          </div>

          <.form for={@form} id="login-form" action={~p"/login"} method="post" class="space-y-4">
            <.input field={@form[:username]} type="text" label="Username" autocomplete="username" />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
            />
            <button type="submit" class="btn btn-primary w-full">Sign in</button>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
