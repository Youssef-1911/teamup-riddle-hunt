// Thin client for the database functions defined in db/schema.sql.
// Every call is `select hunt.<fn>(...)`, which returns a single JSON value.

const SIGNATURES = {
  register_team: ['text'],
  get_team: ['uuid'],
  get_station: ['uuid', 'text'],
  submit_answer: ['uuid', 'text', 'jsonb'],
  report_problem: ['uuid', 'text'],
  leaderboard: [],
  get_settings: [],
  admin_login: ['text'],
  admin_stations: ['text'],
  admin_save_station: ['text', 'jsonb'],
  admin_live: ['text'],
  admin_resolve_report: ['text', 'bigint'],
  admin_team: ['text', 'uuid', 'text', 'text'],
  admin_reset_game: ['text'],
  admin_save_settings: ['text', 'jsonb'],
  admin_change_password: ['text', 'text'],
  upload_photo: ['uuid', 'text', 'jsonb'],
  admin_photos: ['text', 'bigint'],
  admin_photo: ['text', 'bigint'],
  admin_reject_photo: ['text', 'bigint'],
};

// The connection is stored in parts (see assets/config.js) and assembled here.
function connectionUrl(cfg) {
  if (cfg.DATABASE_URL) return cfg.DATABASE_URL;
  const db = cfg.db;
  if (!db || !db.host) return '';
  const secret = encodeURIComponent(atob(db.key));
  return ['postgresql:', '', `${db.user}:${secret}@${db.host}`, `${db.name}?sslmode=require`].join('/');
}

const url = connectionUrl(window.TEAMUP_CONFIG || {});
const isLocal = ['localhost', '127.0.0.1'].includes(location.hostname);
// Without a connection, a local preview talks to the dev server's test database.
const useDevServer = !url && isLocal;

let sqlPromise = null;
function getSql() {
  if (!sqlPromise) {
    sqlPromise = import('https://cdn.jsdelivr.net/npm/@neondatabase/serverless@1.2.0/+esm')
      .then(({ neon }) => neon(url, { disableWarningInBrowsers: true }));
  }
  return sqlPromise;
}

async function query(text, params) {
  if (useDevServer) {
    const res = await fetch('/__sql', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text, params }),
    });
    const body = await res.json();
    if (!res.ok) throw new Error(body.error || 'Database error');
    return body.rows;
  }
  if (!url) throw new Error('Database is not configured');
  const sql = await getSql();
  return sql.query(text, params);
}

export async function rpc(fn, ...args) {
  const types = SIGNATURES[fn];
  if (!types) throw new Error('Unknown function ' + fn);
  // one parameter per declared argument; omitted trailing arguments are sent as NULL
  const params = types.map((t, i) => {
    const v = args[i];
    return v === undefined || v === null ? null : t === 'jsonb' ? JSON.stringify(v) : String(v);
  });
  const placeholders = types.map((t, i) => `$${i + 1}::${t}`).join(', ');
  const rows = await query(`select hunt.${fn}(${placeholders}) as r`, params);
  return rows[0].r;
}

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
