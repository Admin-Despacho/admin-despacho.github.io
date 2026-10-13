// Inventario de tablas de public para el backup (orden de restauración respetando FKs).
// Toda tabla nueva debe agregarse acá: el test BKP-INV falla si aparece una tabla no clasificada.
export const BACKUP_TABLES = [
  // catálogos y configuración
  'roles', 'permissions', 'role_permissions', 'module_permissions', 'carriers', 'app_settings', 'financial_rules', 'dispatch_settings', 'notification_settings',
  'internal_route_notification_settings', 'report_settings', 'transport_cost_settings', 'sheet_templates', 'client_locations',
  // identidades (profiles.id → auth.users: ver scripts/restore_backup.mjs)
  'profiles', 'user_carriers', 'user_passkeys', 'webauthn_challenges',
  // vehículos
  'vehicles', 'vehicle_services', 'vehicle_service_alerts',
  // importaciones y financiación
  'source_imports', 'financial_document_groups', 'financial_document_parts', 'financing_plans',
  // hojas
  'routing_rules', 'route_sequences', 'route_number_counters', 'routes', 'route_drafts', 'route_stops', 'route_change_events', 'route_approval_requests', 'route_return_requests',
  'route_financing_snapshots', 'order_reservations', 'shipping_amount_confirmations', 'stop_outcome_ops', 'stop_evidence', 'customer_identity_docs', 'route_pdfs',
  // NOC
  'credit_notes', 'credit_note_applications', 'credit_note_events',
  // informes y emails
  'commercial_reports', 'report_emails', 'approval_email_jobs', 'customer_email_jobs', 'sheet_email_jobs', 'notifications',
  // auditoría
  'audit_log'
];
// Tablas existentes que NO se respaldan (con motivo). Vacío: hoy todas se respaldan.
// route_number_counters: allocator diario de 2B.1, reemplazado por route_sequences (RC1.1); se respalda igual por si tiene datos históricos.
export const EXCLUDED_TABLES = {};
