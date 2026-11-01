# SQL paths

- `migrations/20261028_equipment.sql` then `20261031_fleet_participation.sql`: clean installation, or a compatible already-installed base for the second script.
- `upgrades/20261101_upgrade_existing_equipment.sql`: **alternative manual path**, only for existing equipment/expenses/links without a private ledger or contractors. Do not run the two original scripts before or after this bridge. It installs the missing base/PR3 dependencies while preserving existing rows.

The alternative path is outside `migrations/` so it is not accidentally replayed after a clean installation by a migration runner. No SQL is executed by the application or by this PR. Production execution requires separate confirmation and schema/policy review. See `docs/LEGACY-EQUIPMENT-UPGRADE.md`.
