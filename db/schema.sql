-- TEAM-UP Riddle Hunt — database schema (Postgres / Neon)
--
-- Safe to re-run: tables are created only if missing and functions are replaced.
-- Run as the database owner. The browser connects as the limited role `hunt_app`,
-- which can ONLY execute the functions granted at the bottom of this file:
-- it cannot read tables directly, so correct answers and the admin password hash
-- never leave the database. Admin functions additionally require the admin password.

create extension if not exists pgcrypto;
create schema if not exists hunt;

-- ───────────────────────────── Tables ─────────────────────────────

create table if not exists hunt.stations (
  id          text primary key,              -- matches the printed QR hash, e.g. 'ev2-station1'
  position    int  not null unique,
  label       text not null default '',      -- small category label shown above the question
  type        text not null default 'mcq'
              check (type in ('mcq', 'order', 'pin', 'truefalse', 'mission')),
  prompt      text not null default '',
  options     jsonb not null default '[]',   -- mcq: choices; order: items in the CORRECT order
  answer      jsonb,                         -- mcq: index; truefalse: bool; pin: text; mission: optional code
  hint        text not null default '',
  hint_after  int  not null default 3 check (hint_after >= 0),
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);

create table if not exists hunt.teams (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  created_at      timestamptz not null default now(),
  last_seen       timestamptz not null default now(),
  current_station text references hunt.stations(id) on delete set null,
  finished_at     timestamptz
);
create unique index if not exists teams_name_key on hunt.teams (lower(name));

create table if not exists hunt.progress (
  team_id     uuid not null references hunt.teams(id) on delete cascade,
  station_id  text not null references hunt.stations(id) on delete cascade,
  first_seen  timestamptz not null default now(),
  wrong_count int not null default 0,
  solved_at   timestamptz,
  primary key (team_id, station_id)
);

create table if not exists hunt.reports (
  id          bigint generated always as identity primary key,
  team_id     uuid references hunt.teams(id) on delete set null,
  team_name   text not null,
  station_id  text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);

-- photo missions: players must upload a photo to complete the station
alter table hunt.stations add column if not exists photo_required boolean not null default true;

create table if not exists hunt.photos (
  id          bigint generated always as identity primary key,
  team_id     uuid not null references hunt.teams(id) on delete cascade,
  station_id  text not null references hunt.stations(id) on delete cascade,
  created_at  timestamptz not null default now(),
  image       bytea not null,   -- JPEG, resized on the phone (max ~1280px)
  thumb       bytea not null,   -- small JPEG for the admin gallery
  unique (team_id, station_id)
);

create table if not exists hunt.settings (
  key   text primary key,
  value text not null
);

create table if not exists hunt.admin_auth (
  id      int primary key check (id = 1),
  pw_hash text not null
);

create table if not exists hunt.admin_failures (
  at timestamptz not null default now()
);

-- ───────────────────────────── Internal helpers ─────────────────────────────

-- Normalises a typed code: trims, lowercases, removes spaces, and maps
-- Arabic-Indic / Persian digits to ASCII so "٤٨٢١" matches "4821".
create or replace function hunt._norm(p text) returns text
language sql immutable as $$
  select lower(regexp_replace(
           translate(coalesce(p, ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789'),
           '\s', '', 'g'))
$$;

-- True when the admin password is correct. Wrong attempts are logged and, after
-- 30 failures in 10 minutes, every attempt is refused until the window passes.
create or replace function hunt._admin_ok(p_pw text) returns boolean
language plpgsql security definer set search_path = hunt, public, pg_temp as $$
declare
  v_hash text;
begin
  delete from admin_failures where at < now() - interval '1 day';
  if (select count(*) from admin_failures where at > now() - interval '10 minutes') >= 30 then
    return false;
  end if;
  select pw_hash into v_hash from admin_auth where id = 1;
  if v_hash is not null and v_hash = crypt(coalesce(p_pw, ''), v_hash) then
    return true;
  end if;
  insert into admin_failures default values;
  return false;
end $$;

create or replace function hunt._total() returns int
language sql stable security definer set search_path = hunt, pg_temp as $$
  select count(*)::int from stations where active
$$;

create or replace function hunt._solved(p_team uuid) returns int
language sql stable security definer set search_path = hunt, pg_temp as $$
  select count(*)::int
  from progress p join stations s on s.id = p.station_id
  where p.team_id = p_team and p.solved_at is not null and s.active
$$;

-- What a player is allowed to see of a station (never the answer).
create or replace function hunt._station_public(s hunt.stations) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  v_opts jsonb := s.options;
  v_code text := hunt._norm(s.answer #>> '{}');
  i int := 0;
begin
  if s.type = 'order' and jsonb_array_length(s.options) > 1 then
    -- shuffle, and make sure the shuffle is not already the solution
    loop
      select jsonb_agg(e order by random()) into v_opts from jsonb_array_elements(s.options) e;
      i := i + 1;
      exit when v_opts is distinct from s.options or i > 20;
    end loop;
  elsif s.type in ('pin', 'truefalse', 'mission') then
    v_opts := '[]';
  end if;

  return json_build_object(
    'id', s.id,
    'position', s.position,
    'label', s.label,
    'type', s.type,
    'prompt', s.prompt,
    'options', v_opts,
    'pin_length', case when s.type = 'pin' then length(v_code) end,
    'pin_numeric', case when s.type in ('pin', 'mission') then v_code ~ '^[0-9]*$' end,
    'needs_code', case when s.type = 'mission' then v_code <> '' end,
    'photo_required', case when s.type = 'mission' then s.photo_required end
  );
end $$;

-- ───────────────────────────── Player API ─────────────────────────────

create or replace function hunt.register_team(p_name text) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_new  boolean;
  t      teams;
begin
  if length(v_name) < 1 or length(v_name) > 40 then
    return json_build_object('error', 'invalid_name');
  end if;
  insert into teams (name) values (v_name) on conflict (lower(name)) do nothing returning * into t;
  v_new := t.id is not null;
  if not v_new then
    update teams set last_seen = now() where lower(name) = lower(v_name) returning * into t;
  end if;
  return json_build_object('id', t.id, 'name', t.name, 'joined', not v_new);
end $$;

-- Team summary for the home screen: progress over all stations.
create or replace function hunt.get_team(p_team uuid) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  t teams;
  v_solved int;
  v_total int := _total();
begin
  select * into t from teams where id = p_team;
  if not found then return json_build_object('error', 'no_team'); end if;
  v_solved := _solved(p_team);
  -- stations may have been opened/closed by an admin since the last answer
  update teams set last_seen = now(),
         finished_at = case when v_total > 0 and v_solved >= v_total then coalesce(finished_at, now()) end
  where id = p_team;
  return json_build_object(
    'team', json_build_object('id', t.id, 'name', t.name),
    'solved', v_solved,
    'total', v_total,
    'finished', v_total > 0 and v_solved >= v_total,
    'stations', (
      select coalesce(json_agg(json_build_object(
               'id', s.id, 'position', s.position,
               'solved', p.solved_at is not null) order by s.position), '[]')
      from stations s
      left join progress p on p.station_id = s.id and p.team_id = p_team
      where s.active)
  );
end $$;

-- Called when a team scans a station QR: records where they are and returns the question.
create or replace function hunt.get_station(p_team uuid, p_station text) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  t teams;
  s stations;
  p progress;
begin
  select * into t from teams where id = p_team;
  if not found then return json_build_object('error', 'no_team'); end if;
  select * into s from stations where id = p_station;
  if not found then return json_build_object('error', 'no_station'); end if;

  update teams set last_seen = now(), current_station = s.id where id = t.id;

  if not s.active then
    return json_build_object('error', 'closed', 'team', json_build_object('id', t.id, 'name', t.name));
  end if;

  insert into progress (team_id, station_id) values (t.id, s.id) on conflict do nothing;
  select * into p from progress where team_id = t.id and station_id = s.id;

  return json_build_object(
    'team', json_build_object('id', t.id, 'name', t.name),
    'station', _station_public(s),
    'solved', p.solved_at is not null,
    'wrong_count', p.wrong_count,
    'hint', case when s.hint <> '' and p.wrong_count >= s.hint_after then s.hint end,
    'solved_count', _solved(t.id),
    'total', _total(),
    'finished', t.finished_at is not null
  );
end $$;

create or replace function hunt.submit_answer(p_team uuid, p_station text, p_answer jsonb) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  t teams;
  s stations;
  p progress;
  v_ok boolean;
  v_solved int;
  v_total int;
begin
  select * into t from teams where id = p_team;
  if not found then return json_build_object('error', 'no_team'); end if;
  select * into s from stations where id = p_station;
  if not found then return json_build_object('error', 'no_station'); end if;
  if not s.active then return json_build_object('error', 'closed'); end if;

  insert into progress (team_id, station_id) values (t.id, s.id) on conflict do nothing;
  select * into p from progress where team_id = t.id and station_id = s.id for update;

  if p.solved_at is null then
    v_ok := case s.type
      when 'mcq'       then jsonb_typeof(p_answer) = 'number' and p_answer = s.answer
      when 'truefalse' then jsonb_typeof(p_answer) = 'boolean' and p_answer = s.answer
      when 'order'     then p_answer = s.options
      when 'pin'       then _norm(s.answer #>> '{}') <> '' and _norm(p_answer #>> '{}') = _norm(s.answer #>> '{}')
      when 'mission'   then (not s.photo_required or exists (select 1 from photos ph where ph.team_id = t.id and ph.station_id = s.id))
                        and (_norm(s.answer #>> '{}') = '' or _norm(p_answer #>> '{}') = _norm(s.answer #>> '{}'))
    end;
    v_ok := coalesce(v_ok, false);

    if v_ok then
      update progress set solved_at = now() where team_id = t.id and station_id = s.id returning * into p;
    else
      update progress set wrong_count = wrong_count + 1 where team_id = t.id and station_id = s.id returning * into p;
    end if;
  else
    v_ok := true;
  end if;

  v_solved := _solved(t.id);
  v_total := _total();
  update teams set last_seen = now(), current_station = s.id,
         finished_at = case when v_total > 0 and v_solved >= v_total then coalesce(finished_at, now()) end
  where id = t.id;

  return json_build_object(
    'correct', v_ok,
    'solved_count', v_solved,
    'total', v_total,
    'finished', v_total > 0 and v_solved >= v_total,
    'wrong_count', p.wrong_count,
    'hint', case when not v_ok and s.hint <> '' and p.wrong_count >= s.hint_after then s.hint end
  );
end $$;

create or replace function hunt.report_problem(p_team uuid, p_station text) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  v_name text;
  v_station text := (select id from stations where id = p_station);
begin
  select name into v_name from teams where id = p_team;
  -- ignore repeated taps: one open report per team+station every 2 minutes
  if exists (select 1 from reports
             where team_id is not distinct from (case when v_name is null then null else p_team end)
               and station_id is not distinct from v_station
               and resolved_at is null and created_at > now() - interval '2 minutes') then
    return json_build_object('ok', true);
  end if;
  insert into reports (team_id, team_name, station_id)
  values (case when v_name is null then null else p_team end,
          coalesce(v_name, 'غير مسجل'),
          v_station);
  return json_build_object('ok', true);
end $$;

create or replace function hunt.leaderboard() returns json
language sql stable security definer set search_path = hunt, pg_temp as $$
  select json_build_object(
    'total', _total(),
    'teams', coalesce(json_agg(row_to_json(r) order by r.solved desc, r.finished_at nulls last, r.last_solved_at nulls last, r.name), '[]')
  )
  from (
    select t.name,
           case when _total() > 0 and count(p.solved_at) filter (where s.active) >= _total() then t.finished_at end as finished_at,
           count(p.solved_at) filter (where s.active)::int as solved,
           max(p.solved_at) as last_solved_at
    from teams t
    left join progress p on p.team_id = t.id
    left join stations s on s.id = p.station_id
    group by t.id
  ) r
$$;

create or replace function hunt.get_settings() returns json
language sql stable security definer set search_path = hunt, pg_temp as $$
  select coalesce(json_object_agg(key, value), '{}') from settings
$$;

-- ───────────────────────────── Admin API ─────────────────────────────

create or replace function hunt.admin_login(p_pw text) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
begin
  return json_build_object('ok', _admin_ok(p_pw));
end $$;

create or replace function hunt.admin_stations(p_pw text) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  return (select coalesce(json_agg(row_to_json(s) order by s.position), '[]') from stations s);
end $$;

create or replace function hunt.admin_save_station(p_pw text, p jsonb) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  v_type text := p->>'type';
  v_opts jsonb := coalesce(p->'options', '[]');
  v_ans  jsonb := p->'answer';
  v_n    int;
  s      stations;
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  if v_type not in ('mcq', 'order', 'pin', 'truefalse', 'mission') then
    return json_build_object('error', 'Unknown question type');
  end if;
  if btrim(coalesce(p->>'prompt', '')) = '' then
    return json_build_object('error', 'The question text is empty');
  end if;
  if jsonb_typeof(v_opts) <> 'array' then
    return json_build_object('error', 'Options must be a list');
  end if;

  -- drop blank options, keep order
  select coalesce(jsonb_agg(to_jsonb(btrim(e)) order by ord), '[]') into v_opts
  from jsonb_array_elements_text(v_opts) with ordinality as x(e, ord)
  where btrim(e) <> '';
  v_n := jsonb_array_length(v_opts);

  if v_type = 'mcq' then
    if v_n < 2 then return json_build_object('error', 'Multiple choice needs at least 2 options'); end if;
    if jsonb_typeof(v_ans) <> 'number' or (v_ans)::int < 0 or (v_ans)::int >= v_n then
      return json_build_object('error', 'Pick the correct option');
    end if;
  elsif v_type = 'order' then
    if v_n < 2 then return json_build_object('error', 'Ordering needs at least 2 items'); end if;
    if (select count(distinct e) from jsonb_array_elements_text(v_opts) e) <> v_n then
      return json_build_object('error', 'Ordering items must all be different');
    end if;
    v_ans := null;
  elsif v_type = 'truefalse' then
    if jsonb_typeof(v_ans) <> 'boolean' then return json_build_object('error', 'Choose True or False'); end if;
    v_opts := '[]';
  elsif v_type = 'pin' then
    if _norm(v_ans #>> '{}') = '' then return json_build_object('error', 'Enter the PIN code'); end if;
    v_ans := to_jsonb(_norm(v_ans #>> '{}'));
    v_opts := '[]';
  elsif v_type = 'mission' then
    v_ans := case when _norm(v_ans #>> '{}') = '' then null else to_jsonb(_norm(v_ans #>> '{}')) end;
    v_opts := '[]';
  end if;

  update stations set
    label      = btrim(coalesce(p->>'label', '')),
    type       = v_type,
    prompt     = btrim(p->>'prompt'),
    options    = v_opts,
    answer     = v_ans,
    hint       = btrim(coalesce(p->>'hint', '')),
    hint_after = greatest(0, coalesce((p->>'hint_after')::int, 3)),
    photo_required = coalesce((p->>'photo_required')::boolean, true),
    active     = coalesce((p->>'active')::boolean, true),
    updated_at = now()
  where id = p->>'id'
  returning * into s;
  if not found then return json_build_object('error', 'Station not found'); end if;

  return json_build_object('ok', true, 'station', row_to_json(s));
end $$;

create or replace function hunt.admin_live(p_pw text) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  return json_build_object(
    'now', now(),
    'total', _total(),
    'stations', (select coalesce(json_agg(json_build_object(
                   'id', id, 'position', position, 'label', label, 'type', type, 'active', active)
                   order by position), '[]') from stations),
    'teams', (
      select coalesce(json_agg(row_to_json(r) order by r.solved desc, r.finished_at nulls last, r.last_solved_at nulls last, r.name), '[]')
      from (
        select t.id, t.name, t.created_at, t.last_seen, t.current_station,
               case when _total() > 0 and count(p.solved_at) filter (where s.active) >= _total() then t.finished_at end as finished_at,
               cs.position as current_position,
               count(p.solved_at) filter (where s.active)::int as solved,
               coalesce(sum(p.wrong_count), 0)::int as wrong,
               max(p.solved_at) as last_solved_at,
               coalesce(json_agg(p.station_id) filter (where p.solved_at is not null), '[]') as solved_ids,
               coalesce(json_agg(p.station_id) filter (where p.solved_at is null), '[]') as open_ids
        from teams t
        left join stations cs on cs.id = t.current_station
        left join progress p on p.team_id = t.id
        left join stations s on s.id = p.station_id
        group by t.id, cs.position
      ) r),
    'reports', (select coalesce(json_agg(json_build_object(
                  'id', r.id, 'team_name', r.team_name, 'station_id', r.station_id,
                  'position', s.position, 'created_at', r.created_at) order by r.created_at), '[]')
                from reports r left join stations s on s.id = r.station_id
                where r.resolved_at is null)
  );
end $$;

create or replace function hunt.admin_resolve_report(p_pw text, p_id bigint) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  update reports set resolved_at = now() where id = p_id and resolved_at is null;
  return json_build_object('ok', true);
end $$;

-- p_action: 'delete' | 'reset' | 'solve' | 'unsolve' | 'rename'
create or replace function hunt.admin_team(p_pw text, p_team uuid, p_action text, p_arg text default null) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  v_name text;
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  if p_action = 'delete' then
    delete from teams where id = p_team;
  elsif p_action = 'reset' then
    delete from progress where team_id = p_team;
    delete from photos where team_id = p_team;
    update teams set finished_at = null, current_station = null where id = p_team;
  elsif p_action in ('solve', 'unsolve') then
    insert into progress (team_id, station_id) values (p_team, p_arg) on conflict do nothing;
    update progress set solved_at = case when p_action = 'solve' then coalesce(solved_at, now()) end
    where team_id = p_team and station_id = p_arg;
    update teams set finished_at = case when _total() > 0 and _solved(p_team) >= _total() then coalesce(finished_at, now()) end
    where id = p_team;
  elsif p_action = 'rename' then
    v_name := btrim(regexp_replace(coalesce(p_arg, ''), '\s+', ' ', 'g'));
    if length(v_name) < 1 or length(v_name) > 40 then return json_build_object('error', 'Invalid name'); end if;
    if exists (select 1 from teams where lower(name) = lower(v_name) and id <> p_team) then
      return json_build_object('error', 'Another team already has that name');
    end if;
    update teams set name = v_name where id = p_team;
  else
    return json_build_object('error', 'Unknown action');
  end if;
  return json_build_object('ok', true);
end $$;

create or replace function hunt.admin_reset_game(p_pw text) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  delete from reports;
  delete from teams;   -- cascades to progress
  return json_build_object('ok', true);
end $$;

create or replace function hunt.admin_save_settings(p_pw text, p jsonb) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  insert into settings (key, value)
  select key, btrim(value) from jsonb_each_text(p)
  where key in ('event_title', 'finish_title', 'finish_message', 'home_message')
  on conflict (key) do update set value = excluded.value;
  return json_build_object('ok', true);
end $$;

create or replace function hunt.admin_change_password(p_pw text, p_new text) returns json
language plpgsql security definer set search_path = hunt, public, pg_temp as $$
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  if length(coalesce(p_new, '')) < 4 then
    return json_build_object('error', 'The new password must be at least 4 characters');
  end if;
  update admin_auth set pw_hash = crypt(p_new, gen_salt('bf')) where id = 1;
  return json_build_object('ok', true);
end $$;

-- ───────────────────────────── Photos ─────────────────────────────

-- Player uploads the photo for a photo mission. p = {image: base64 jpeg, thumb: base64 jpeg}.
-- Re-uploading replaces the previous photo (new id, so the admin gallery picks it up).
create or replace function hunt.upload_photo(p_team uuid, p_station text, p jsonb) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  s stations;
  v_img bytea;
  v_thumb bytea;
begin
  if not exists (select 1 from teams where id = p_team) then return json_build_object('error', 'no_team'); end if;
  select * into s from stations where id = p_station;
  if not found then return json_build_object('error', 'no_station'); end if;
  if not s.active then return json_build_object('error', 'closed'); end if;
  if s.type <> 'mission' then return json_build_object('error', 'not_mission'); end if;
  if length(coalesce(p->>'image', '')) > 900000 or length(coalesce(p->>'thumb', '')) > 150000 then
    return json_build_object('error', 'too_large');
  end if;
  if (select count(*) from photos) >= 3000 then return json_build_object('error', 'storage_full'); end if;
  begin
    v_img := decode(p->>'image', 'base64');
    v_thumb := decode(p->>'thumb', 'base64');
  exception when others then
    return json_build_object('error', 'bad_image');
  end;
  -- must be a JPEG (FF D8 FF)
  if v_img is null or length(v_img) < 100 or substring(v_img from 1 for 3) <> '\xffd8ff'::bytea
     or v_thumb is null or substring(v_thumb from 1 for 3) <> '\xffd8ff'::bytea then
    return json_build_object('error', 'bad_image');
  end if;

  delete from photos where team_id = p_team and station_id = s.id;
  insert into photos (team_id, station_id, image, thumb) values (p_team, s.id, v_img, v_thumb);
  update teams set last_seen = now(), current_station = s.id where id = p_team;
  return json_build_object('ok', true);
end $$;

-- Gallery: photos newer than p_after (thumbnails only) + ids of all current photos.
create or replace function hunt.admin_photos(p_pw text, p_after bigint) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  return json_build_object(
    'ids', (select coalesce(json_agg(id order by id), '[]') from photos),
    'photos', (
      select coalesce(json_agg(json_build_object(
               'id', ph.id, 'team_id', ph.team_id, 'team_name', t.name,
               'station_id', ph.station_id, 'position', s.position, 'label', s.label,
               'created_at', ph.created_at, 'thumb', translate(encode(ph.thumb, 'base64'), E'\n', '')) order by ph.id), '[]')
      from photos ph
      join teams t on t.id = ph.team_id
      join stations s on s.id = ph.station_id
      where ph.id > coalesce(p_after, 0))
  );
end $$;

create or replace function hunt.admin_photo(p_pw text, p_id bigint) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  v text;
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  -- encode() wraps base64 every 76 characters; strip the line breaks
  select translate(encode(image, 'base64'), E'\n', '') into v from photos where id = p_id;
  if v is null then return json_build_object('error', 'not_found'); end if;
  return json_build_object('image', v);
end $$;

-- Reject: delete the photo and reopen the station for that team (they must redo it).
create or replace function hunt.admin_reject_photo(p_pw text, p_id bigint) returns json
language plpgsql security definer set search_path = hunt, pg_temp as $$
declare
  ph photos;
begin
  if not _admin_ok(p_pw) then return json_build_object('error', 'auth'); end if;
  delete from photos where id = p_id returning * into ph;
  if ph.id is null then return json_build_object('ok', true); end if;
  update progress set solved_at = null where team_id = ph.team_id and station_id = ph.station_id;
  update teams set finished_at = case when _total() > 0 and _solved(ph.team_id) >= _total() then finished_at end
  where id = ph.team_id;
  return json_build_object('ok', true);
end $$;

-- ───────────────────────────── Permissions ─────────────────────────────

revoke all on all tables in schema hunt from public;
revoke all on all functions in schema hunt from public;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'hunt_app') then
    execute 'grant usage on schema hunt to hunt_app';
    execute 'revoke all on all tables in schema hunt from hunt_app';
    execute 'revoke all on all functions in schema hunt from hunt_app';
    execute $g$grant execute on function
      hunt.register_team(text),
      hunt.get_team(uuid),
      hunt.get_station(uuid, text),
      hunt.submit_answer(uuid, text, jsonb),
      hunt.report_problem(uuid, text),
      hunt.leaderboard(),
      hunt.get_settings(),
      hunt.admin_login(text),
      hunt.admin_stations(text),
      hunt.admin_save_station(text, jsonb),
      hunt.admin_live(text),
      hunt.admin_resolve_report(text, bigint),
      hunt.admin_team(text, uuid, text, text),
      hunt.admin_reset_game(text),
      hunt.admin_save_settings(text, jsonb),
      hunt.admin_change_password(text, text),
      hunt.upload_photo(uuid, text, jsonb),
      hunt.admin_photos(text, bigint),
      hunt.admin_photo(text, bigint),
      hunt.admin_reject_photo(text, bigint)
    to hunt_app$g$;
  end if;
end $$;
