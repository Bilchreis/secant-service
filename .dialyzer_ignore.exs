# Warnings Dialyzer reports that are expected. Each entry says why.
[
  # Struct plots have their own builder; this callback raises on purpose.
  {"lib/secant_service/plot_db/dtypes/struct.ex", :no_return},
  # From the code ash_authentication_phoenix's controller macro injects.
  {"lib/ash_authentication_phoenix/controller.ex", :unknown_type}
]
