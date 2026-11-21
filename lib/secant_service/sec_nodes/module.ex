defmodule SecantService.SecNodes.Module do
  use Ash.Resource,
    domain: SecantService.SecNodes,
    data_layer: AshPostgres.DataLayer

  alias SecantService.Util

  postgres do
    table "modules"
    repo SecantService.Repo

    references do
      reference :sec_node do
        on_delete :delete
      end
    end

    identity_index_names sec_node_id_name: "modules_sec_node_id_name_index"
  end

  actions do
    defaults [:read, :destroy]

    read :get_node_id do
      argument :id, :integer, allow_nil?: false
      filter expr(id == ^arg(:id))
      prepare build(select: [:id, :sec_node_id], load: [sec_node: [:node_id]])
      get? true
    end

    create :create do
      primary? true

      accept [
        :name,
        :description,
        :interface_classes,
        :highest_interface_class,
        :visibility,
        :group,
        :meaning,
        :implementor,
        :custom_properties,
        :sec_node_id
      ]

      argument :parameters, {:array, :map}
      argument :commands, {:array, :map}

      upsert? true
      upsert_identity :sec_node_id_name

      upsert_fields [
        :description,
        :interface_classes,
        :highest_interface_class,
        :visibility,
        :group,
        :meaning,
        :implementor,
        :custom_properties
      ]

      change manage_relationship(:parameters, type: :create)
      change manage_relationship(:commands, type: :create)
    end
  end

  attributes do
    attribute :id, :integer do
      primary_key? true
      allow_nil? false
      generated? true
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :interface_classes, {:array, :string} do
      public? true
    end

    attribute :highest_interface_class, :string do
      public? true
    end

    attribute :visibility, :string do
      public? true
    end

    attribute :group, :string do
      public? true
    end

    attribute :meaning, :map do
      public? true
    end

    attribute :implementor, :string do
      public? true
    end

    attribute :custom_properties, :map do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :sec_node, SecantService.SecNodes.SecNode do
      destination_attribute :uuid
      allow_nil? false
      public? true
    end

    has_many :commands, SecantService.SecNodes.Command do
      public? true
    end

    has_many :parameters, SecantService.SecNodes.Parameter do
      public? true
    end
  end

  aggregates do
    sum :datapoint_count, :parameters, :datapoint_count
    sum :disk_size_bytes, :parameters, :disk_size_bytes
  end

  identities do
    identity :sec_node_id_name, [:sec_node_id, :name]
  end

  # Helper functions that work on loaded structs
  def display_name(module) do
    Util.display_name(module.name)
  end

  def has_status?(module) do
    case module.parameters do
      %Ash.NotLoaded{} ->
        raise "parameters must be loaded to check for status parameter"

      parameters ->
        Enum.any?(parameters, fn param -> param.name == "status" end)
    end
  end

  def get_parameter(module, param_name) do
    case module.parameters do
      %Ash.NotLoaded{} ->
        raise "parameters must be loaded to get parameter: #{param_name}"

      parameters ->
        Enum.find(parameters, fn param -> param.name == param_name end)
    end
  end
end
