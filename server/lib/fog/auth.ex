defmodule Fog.Authentication do
  import Ecto.Query
  alias Fog.Authentication.Token
  alias Fog.Repo

  defmodule Token do
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    schema "agent_tokens" do
      field(:token, :string)
      field(:description, :string)
      field(:last_used_at, :utc_datetime)
      field(:active, :boolean, default: true)

      timestamps()
    end

    def changeset(token, attrs) do
      token
      |> cast(attrs, [:token, :description, :active])
      |> validate_required([:token])
      |> validate_length(:token, min: 32, max: 255)
      |> unique_constraint(:token)
    end
  end

  defp generate do
    :crypto.strong_rand_bytes(30)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 40)
  end

  def store_token(token, description \\ nil) do
    %Token{}
    |> Token.changeset(%{
      token: token,
      description: description
    })
    |> Repo.insert()
  end

  def create_random(description) do
    %Token{}
    |> Token.changeset(%{
      token: generate(),
      description: description
    })
    |> Repo.insert()
  end

  def validate_token(token) do
    query =
      from(t in Token,
        where: t.token == ^token and t.active == true
      )

    case Repo.one(query) do
      nil ->
        false

      token_record ->
        # Update last_used_at
        token_record
        |> Ecto.Changeset.change(%{last_used_at: DateTime.utc_now()})
        |> Repo.update()

        true
    end
  end

  def deactivate(token) do
    case Repo.get_by(Token, token: token) do
      nil ->
        {:error, :not_found}

      token_record ->
        token_record
        |> Ecto.Changeset.change(%{active: false})
        |> Repo.update()
    end
  end

  def all_active do
    Token
    |> where(active: true)
    |> Repo.all()
  end

  @spec one(String.t()) :: Token.t() | nil
  def one(token) do
    Repo.get_by(Token, token: token)
  end
end
