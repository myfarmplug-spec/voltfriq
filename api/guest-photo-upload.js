const MAX_FILES = 3;
const MAX_BYTES = 2 * 1024 * 1024;
const ALLOWED_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);

export const config = {
  api: {
    bodyParser: {
      sizeLimit: '7mb'
    }
  }
};

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.status(405).json({ ok: false, error: 'Method not allowed' });
    return;
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRoleKey) {
    res.status(500).json({ ok: false, error: 'Missing upload environment variables' });
    return;
  }

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const jobId = String(body.jobId || '').trim();
    const accessToken = String(body.accessToken || '').trim();
    const files = Array.isArray(body.files) ? body.files : [];

    if (!/^[0-9a-f-]{36}$/i.test(jobId) || accessToken.length < 24) {
      res.status(400).json({ ok: false, error: 'Invalid booking upload token.' });
      return;
    }
    if (!files.length || files.length > MAX_FILES) {
      res.status(400).json({ ok: false, error: 'Add up to 3 photos only.' });
      return;
    }

    const uploadedPaths = [];
    for (let index = 0; index < files.length; index += 1) {
      const file = files[index] || {};
      const contentType = String(file.type || '').toLowerCase();
      const originalName = String(file.name || 'photo').slice(0, 120);
      const data = String(file.data || '').replace(/^data:[^,]+,/, '');
      if (!ALLOWED_TYPES.has(contentType)) {
        res.status(400).json({ ok: false, error: 'Only JPG, PNG, or WebP photos are allowed.' });
        return;
      }
      const buffer = Buffer.from(data, 'base64');
      if (!buffer.length || buffer.length > MAX_BYTES) {
        res.status(400).json({ ok: false, error: 'Each photo must be under 2MB.' });
        return;
      }

      const ext = extensionForType(contentType, originalName);
      const filePath = `guest/${jobId}/${accessToken.slice(0, 16)}/${Date.now()}-${index}${ext}`;
      const uploadResponse = await fetch(`${supabaseUrl}/storage/v1/object/job-photos/${encodeStoragePath(filePath)}`, {
        method: 'POST',
        headers: {
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
          'Content-Type': contentType,
          'x-upsert': 'false',
          'Cache-Control': '3600'
        },
        body: buffer
      });

      if (!uploadResponse.ok) {
        const detail = await uploadResponse.text();
        res.status(uploadResponse.status).json({ ok: false, error: 'Photo upload failed.', detail });
        return;
      }
      uploadedPaths.push(filePath);
    }

    const attachResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/attach_guest_job_photos`, {
      method: 'POST',
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        p_job_id: jobId,
        p_access_token: accessToken,
        p_photo_paths: uploadedPaths
      })
    });

    const text = await attachResponse.text();
    let payload = null;
    try {
      payload = text ? JSON.parse(text) : null;
    } catch (error) {
      payload = text;
    }
    if (!attachResponse.ok) {
      res.status(attachResponse.status).json({ ok: false, error: 'Could not attach photos to booking.', detail: payload });
      return;
    }

    res.status(200).json({ ok: true, photoPaths: uploadedPaths, job: payload });
  } catch (error) {
    res.status(500).json({ ok: false, error: error && error.message ? error.message : 'Unexpected photo upload failure' });
  }
}

function extensionForType(contentType, originalName) {
  if (contentType === 'image/png') return '.png';
  if (contentType === 'image/webp') return '.webp';
  if (/\.jpe?g$/i.test(originalName)) return originalName.match(/\.jpe?g$/i)[0].toLowerCase();
  return '.jpg';
}

function encodeStoragePath(value) {
  return String(value || '').split('/').map(encodeURIComponent).join('/');
}
