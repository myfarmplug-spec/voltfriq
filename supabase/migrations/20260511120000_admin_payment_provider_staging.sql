alter table public.admin_settings
  add column if not exists payment_configuration jsonb not null default '{
    "active_provider": "manual",
    "preferred_provider": "",
    "providers": {
      "manual": {
        "enabled": true
      },
      "paystack": {
        "enabled": false,
        "public_key": "",
        "secret_key": "",
        "webhook_secret": "",
        "subaccount_code": ""
      },
      "remita": {
        "enabled": false,
        "merchant_id": "",
        "service_type_id": "",
        "api_key": "",
        "gateway_url": ""
      }
    }
  }'::jsonb;
