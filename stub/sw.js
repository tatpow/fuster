self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  if (url.pathname === '/api/v1/auth/login' && event.request.method === 'POST') {
    event.respondWith(
      (async () => {
        
        const delay = Math.floor(Math.random() * 500) + 400;
        await new Promise(resolve => setTimeout(resolve, delay));

        
        return new Response(
          JSON.stringify({
            success: false,
            error: 'Unauthorized',
            message: 'Пользователь не найден или неверный пароль'
          }),
          {
            status: 401,
            statusText: 'Unauthorized',
            headers: { 'Content-Type': 'application/json' }
          }
        );
      })()
    );
  }
});
