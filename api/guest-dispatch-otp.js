const OTP_ACTION = 'dispatch_confirm';

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false, error: 'Method not allowed' });
    return;
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRoleKey) {
    res.status(500).json({ ok: false, error: 'Missing OTP environment variables' });
    return;
  }

  let challengeId = null;
  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const jobId = String(body.jobId || '').trim();
    const accessToken = String(body.accessToken || '').trim();
    const phoneConfirmation = String(body.phoneConfirmation || '').trim();
    const clientFingerprint = String(body.clientFingerprint || '').trim();

    if (!/^[0-9a-f-]{36}$/i.test(jobId) || accessToken.length < 24) {
      res.status(400).json({ ok: false, error: 'Invalid booking verification token.' });
      return;
    }

    const otpPayload = await rpc(supabaseUrl, serviceRoleKey, 'create_guest_otp_delivery', {
      p_job_id: jobId,
      p_access_token: accessToken,
      p_action_type: OTP_ACTION,
      p_phone_confirmation: phoneConfirmation,
      p_client_fingerprint: clientFingerprint || null
    });

    challengeId = otpPayload.challenge_id || otpPayload.challengeId;
    const otpCode = String(otpPayload.otp_code || otpPayload.otpCode || '').replace(/\D/g, '');
    const phone = String(otpPayload.phone || '').trim();
    if (!challengeId || otpCode.length !== 6 || !phone) {
      throw new Error('OTP delivery could not be prepared.');
    }

    const sms = await sendSms({
      to: phone,
      message: `Your VoltFriq booking verification code is ${otpCode}. It expires in 10 minutes.`
    });

    await rpc(supabaseUrl, serviceRoleKey, 'mark_guest_otp_delivery', {
      p_challenge_id: challengeId,
      p_delivery_status: 'sent',
      p_metadata: {
        provider: sms.provider,
        provider_message_id: sms.messageId || null,
        sent_at: new Date().toISOString()
      }
    });

    res.status(200).json({
      ok: true,
      challengeId,
      maskedPhone: otpPayload.masked_phone || otpPayload.maskedPhone || maskPhone(phone),
      deliveryStatus: 'sent'
    });
  } catch (error) {
    if (challengeId) {
      await markDeliveryFailure(supabaseUrl, serviceRoleKey, challengeId, error);
    }
    const message = error && error.message ? error.message : 'Could not send dispatch verification code.';
    const status = message.toLowerCase().includes('sms provider') ? 503 : 400;
    res.status(status).json({ ok: false, error: message });
  }
}

async function rpc(supabaseUrl, serviceRoleKey, name, body) {
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(body || {})
  });
  const text = await response.text();
  let payload = null;
  try {
    payload = text ? JSON.parse(text) : null;
  } catch (error) {
    payload = text;
  }
  if (!response.ok) {
    const detail = payload && payload.message ? payload.message : text;
    throw new Error(detail || 'Supabase RPC failed.');
  }
  return payload || {};
}

async function markDeliveryFailure(supabaseUrl, serviceRoleKey, challengeId, error) {
  try {
    await rpc(supabaseUrl, serviceRoleKey, 'mark_guest_otp_delivery', {
      p_challenge_id: challengeId,
      p_delivery_status: 'failed',
      p_metadata: {
        error: error && error.message ? error.message : 'SMS delivery failed',
        failed_at: new Date().toISOString()
      }
    });
  } catch (ignored) {
    // Delivery failure reporting must never hide the original send error.
  }
}

async function sendSms({ to, message }) {
  if (process.env.SMS_WEBHOOK_URL) {
    return sendWebhookSms(to, message);
  }
  if (process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN && (process.env.TWILIO_FROM_NUMBER || process.env.TWILIO_MESSAGING_SERVICE_SID)) {
    return sendTwilioSms(to, message);
  }
  if (process.env.TERMII_API_KEY) {
    return sendTermiiSms(to, message);
  }
  throw new Error('SMS provider is not configured.');
}

async function sendWebhookSms(to, message) {
  const headers = { 'Content-Type': 'application/json' };
  if (process.env.SMS_WEBHOOK_SECRET) {
    headers.Authorization = `Bearer ${process.env.SMS_WEBHOOK_SECRET}`;
  }
  const response = await fetch(process.env.SMS_WEBHOOK_URL, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      to,
      message,
      purpose: 'guest_dispatch_otp',
      app: 'voltfriq'
    })
  });
  const text = await response.text();
  if (!response.ok) throw new Error(text || 'SMS provider webhook failed.');
  let payload = {};
  try { payload = text ? JSON.parse(text) : {}; } catch (error) { payload = { raw: text }; }
  return { provider: 'webhook', messageId: payload.id || payload.message_id || payload.sid || null };
}

async function sendTwilioSms(to, message) {
  const accountSid = process.env.TWILIO_ACCOUNT_SID;
  const authToken = process.env.TWILIO_AUTH_TOKEN;
  const body = new URLSearchParams();
  body.set('To', normalizeInternationalPhone(to));
  body.set('Body', message);
  if (process.env.TWILIO_MESSAGING_SERVICE_SID) {
    body.set('MessagingServiceSid', process.env.TWILIO_MESSAGING_SERVICE_SID);
  } else {
    body.set('From', process.env.TWILIO_FROM_NUMBER);
  }
  const response = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(accountSid)}/Messages.json`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString('base64')}`,
      'Content-Type': 'application/x-www-form-urlencoded'
    },
    body
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.message || 'Twilio SMS delivery failed.');
  return { provider: 'twilio', messageId: payload.sid || null };
}

async function sendTermiiSms(to, message) {
  const response = await fetch(process.env.TERMII_BASE_URL || 'https://api.ng.termii.com/api/sms/send', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      api_key: process.env.TERMII_API_KEY,
      to: normalizeNigerianPhone(to),
      from: process.env.TERMII_SENDER_ID || 'VoltFriq',
      sms: message,
      type: 'plain',
      channel: process.env.TERMII_CHANNEL || 'generic'
    })
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || payload.code === 'failed') {
    throw new Error(payload.message || 'Termii SMS delivery failed.');
  }
  return { provider: 'termii', messageId: payload.message_id || payload.messageId || null };
}

function normalizeInternationalPhone(value) {
  const clean = String(value || '').trim();
  if (clean.startsWith('+')) return clean;
  const digits = clean.replace(/\D/g, '');
  if (digits.startsWith('234')) return `+${digits}`;
  if (digits.startsWith('0')) return `+234${digits.slice(1)}`;
  return `+${digits}`;
}

function normalizeNigerianPhone(value) {
  const digits = String(value || '').replace(/\D/g, '');
  if (digits.startsWith('234')) return digits;
  if (digits.startsWith('0')) return `234${digits.slice(1)}`;
  return digits;
}

function maskPhone(value) {
  const digits = String(value || '').replace(/\D/g, '');
  return digits ? `***${digits.slice(-4)}` : '';
}
