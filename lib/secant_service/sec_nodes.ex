defmodule SecantService.SecNodes do
  @moduledoc """
  Domain for managing SECoP nodes and their metadata.
  """

  use Ash.Domain,
    otp_app: :secant_service

  resources do
    resource SecantService.SecNodes.Command
    resource SecantService.SecNodes.Module
    resource SecantService.SecNodes.ParameterValueArrayBool
    resource SecantService.SecNodes.ParameterValueArrayDouble
    resource SecantService.SecNodes.ParameterValueArrayInt
    resource SecantService.SecNodes.ParameterValueArrayString
    resource SecantService.SecNodes.ParameterValueBool
    resource SecantService.SecNodes.ParameterValueDouble
    resource SecantService.SecNodes.ParameterValueInt
    resource SecantService.SecNodes.ParameterValueJson
    resource SecantService.SecNodes.ParameterValueString
    resource SecantService.SecNodes.Parameter
    resource SecantService.SecNodes.SecNode
  end
end
