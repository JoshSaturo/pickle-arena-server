# Pickle Arena account-enabled relay

Upload `render.yaml` and the `server/` folder to your existing
`JoshSaturo/pickle-arena-server` repository, keeping these paths intact.
`records.dart` is a new required server file.

Read `supabase/SETUP.md` for the database migration, email configuration,
server-only environment variables, and app build configuration. Run the migration
and its SQL test before turning on accounts. The SQL files are in this package;
the app code and `config/` files remain in your Flutter workspace.

Use the existing Render service and manually deploy the new commit after
configuring its Supabase environment variables. Do not create a duplicate
service. Guest matches still work when both Supabase variables are absent.

The package contains no database credentials or player data. Never upload a
Supabase secret/service-role key to this repository or include it in the app.
