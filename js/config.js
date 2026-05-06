window.VOLTFRIQ_CONFIG = window.VOLTFRIQ_CONFIG || {
  supabaseUrl: (window.VOLTFRIQ_ENV && window.VOLTFRIQ_ENV.SUPABASE_URL) || '',
  supabaseAnonKey: (window.VOLTFRIQ_ENV && window.VOLTFRIQ_ENV.SUPABASE_ANON_KEY) || '',
  publicSiteUrl: (window.VOLTFRIQ_ENV && window.VOLTFRIQ_ENV.PUBLIC_SITE_URL) || 'https://www.voltfriq.com',
  storageBuckets: {
    avatars: 'avatars',
    electricianDocuments: 'electrician-documents',
    jobPhotos: 'job-photos',
    paymentProofs: 'payment-proofs'
  }
};
