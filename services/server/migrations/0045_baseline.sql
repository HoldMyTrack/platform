-- The schema as of the former 0001–0045 migrations, from pg_dump --schema-only, and the rows they
-- seeded: the demo account (internal/httpapi.DemoCustomerUserID, IMPLEMENTATION.md §4.10) and its
-- Private locations. internal/db records this file without running it on a database that already
-- has 0045_activity_pending_index.sql. The next migration is 0046.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;

CREATE TABLE public.activities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    source character varying(32) NOT NULL,
    source_detail character varying(255),
    external_id character varying(255),
    activity_type character varying(50) NOT NULL,
    distance_meters numeric(10,2),
    duration_seconds integer,
    moving_seconds integer,
    elevation_gain_m numeric(8,2),
    avg_speed_mps numeric(6,3),
    started_at timestamp with time zone NOT NULL,
    trajectory public.geometry(LineStringM,4326),
    raw_payload_key text,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    name character varying(200),
    in_heatmap_window boolean DEFAULT true NOT NULL,
    track_edit jsonb,
    edit_pending boolean DEFAULT false NOT NULL,
    ingest_complete boolean DEFAULT true NOT NULL,
    split_group uuid,
    split_from bigint,
    split_to bigint,
    timezone text NOT NULL,
    origin_id uuid,
    recorded_started_at timestamp with time zone,
    recorded_ended_at timestamp with time zone,
    raw_bytes bigint,
    editable_times boolean
);

CREATE TABLE public.activity_country (
    activity_id uuid NOT NULL,
    country_id integer NOT NULL
);

CREATE TABLE public.activity_photos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    activity_id uuid NOT NULL,
    taken_at timestamp with time zone,
    route_at timestamp with time zone NOT NULL,
    content_type character varying(32) NOT NULL,
    thumb_content_type character varying(32) NOT NULL,
    width integer NOT NULL,
    height integer NOT NULL,
    bytes integer NOT NULL,
    caption text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    image_key text NOT NULL
);

CREATE TABLE public.activity_region (
    activity_id uuid NOT NULL,
    region_id integer NOT NULL
);

CREATE TABLE public.activity_tile_mask_data (
    activity_id uuid NOT NULL,
    zoom smallint NOT NULL,
    tile_x integer NOT NULL,
    tile_y integer NOT NULL,
    png bytea NOT NULL
);

CREATE TABLE public.activity_tile_masks (
    activity_id uuid NOT NULL,
    zoom smallint DEFAULT 14 NOT NULL,
    tile_x integer NOT NULL,
    tile_y integer NOT NULL,
    rendered_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.admin_boundaries_source (
    only_row boolean DEFAULT true NOT NULL,
    name text NOT NULL,
    loaded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_boundaries_source_only_row_check CHECK (only_row)
);

CREATE TABLE public.admin_countries (
    id integer NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    geom public.geometry(MultiPolygon,4326) NOT NULL
);

CREATE SEQUENCE public.admin_countries_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.admin_countries_id_seq OWNED BY public.admin_countries.id;

CREATE TABLE public.admin_country_parts (
    country_id integer NOT NULL,
    geom public.geometry(Polygon,4326) NOT NULL
);

CREATE TABLE public.admin_region_parts (
    region_id integer NOT NULL,
    geom public.geometry(Polygon,4326) NOT NULL
);

CREATE TABLE public.admin_regions (
    id integer NOT NULL,
    country_id integer NOT NULL,
    overture_id text NOT NULL,
    code text,
    name text NOT NULL,
    geom public.geometry(MultiPolygon,4326) NOT NULL
);

CREATE SEQUENCE public.admin_regions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.admin_regions_id_seq OWNED BY public.admin_regions.id;

CREATE TABLE public.admin_tile_geoms (
    layer text NOT NULL,
    zoom smallint NOT NULL,
    tile_x integer NOT NULL,
    tile_y integer NOT NULL,
    admin_id integer NOT NULL,
    geom public.geometry NOT NULL
);

CREATE TABLE public.admin_tiles_built (
    layer text NOT NULL,
    zoom smallint NOT NULL,
    tile_x integer NOT NULL,
    tile_y integer NOT NULL
);

CREATE TABLE public.auth_handoffs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    challenge text NOT NULL,
    expires_at timestamp with time zone NOT NULL
);

CREATE TABLE public.bike_paths (
    id bigint NOT NULL,
    kind character varying(8) NOT NULL,
    name text,
    geom public.geometry(MultiLineString,3857) NOT NULL,
    osm_id bigint NOT NULL,
    last_seen_import timestamp with time zone NOT NULL,
    CONSTRAINT bike_paths_kind_check CHECK (kind IN ('cycleway', 'shared', 'mtb'))
);

CREATE SEQUENCE public.bike_paths_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.bike_paths_id_seq OWNED BY public.bike_paths.id;

CREATE TABLE public.connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    provider character varying(32) NOT NULL,
    provider_user_id character varying(255) NOT NULL,
    access_token bytea NOT NULL,
    refresh_token bytea,
    expires_at timestamp with time zone,
    scopes text[],
    connected_at timestamp with time zone DEFAULT now() NOT NULL,
    last_synced_at timestamp with time zone,
    last_record_at timestamp with time zone
);

CREATE TABLE public.daily_stats (
    day date NOT NULL,
    key text NOT NULL,
    value double precision NOT NULL,
    taken_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.email_verifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    email character varying(255) NOT NULL
);

CREATE TABLE public.exports (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    job_id bigint,
    lang character varying(8) NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    ready_at timestamp with time zone,
    expires_at timestamp with time zone,
    part_sizes bigint[]
);

CREATE TABLE public.fog_tiles (
    user_id uuid NOT NULL,
    zoom smallint NOT NULL,
    tile_x integer NOT NULL,
    tile_y integer NOT NULL,
    object_key text,
    heatmap_object_key text,
    dirty boolean DEFAULT true NOT NULL,
    rendered_at timestamp with time zone,
    dirty_gen bigint DEFAULT 0 NOT NULL,
    bytes integer,
    heatmap_bytes integer
);

CREATE TABLE public.jobs (
    id bigint NOT NULL,
    kind character varying(32) NOT NULL,
    user_id uuid,
    payload jsonb NOT NULL,
    state character varying(16) DEFAULT 'pending'::character varying NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    last_error text,
    run_after timestamp with time zone DEFAULT now() NOT NULL,
    locked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    error_code character varying(32),
    finished_at timestamp with time zone,
    raw bytea
);

CREATE SEQUENCE public.jobs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.jobs_id_seq OWNED BY public.jobs.id;

CREATE TABLE public.password_resets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL
);

CREATE TABLE public.privacy_zones (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    center public.geography(Point,4326) NOT NULL,
    radius_m integer DEFAULT 200 NOT NULL,
    name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    salt uuid DEFAULT gen_random_uuid() NOT NULL
);

CREATE TABLE public.r2_ops (
    day date NOT NULL,
    class character(1) NOT NULL,
    count bigint NOT NULL,
    CONSTRAINT r2_ops_class_check CHECK ((class = ANY (ARRAY['A'::bpchar, 'B'::bpchar])))
);

CREATE TABLE public.received_origins (
    user_id uuid NOT NULL,
    origin_id uuid NOT NULL
);

CREATE TABLE public.sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL
);

CREATE TABLE public.spot_captures (
    user_id uuid NOT NULL,
    spot_id bigint NOT NULL,
    captured_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.spots (
    id bigint NOT NULL,
    category character varying(16) NOT NULL,
    name text,
    address text,
    description text,
    inscription text,
    memorial text,
    start_date text,
    wikipedia text,
    geom public.geometry(MultiPolygon,4326) NOT NULL,
    osm_type character varying(8) NOT NULL,
    osm_id bigint NOT NULL,
    last_seen_import timestamp with time zone,
    retired_at timestamp with time zone,
    CONSTRAINT spots_category_check CHECK (category IN ('playground', 'dog_park', 'monument', 'viewpoint', 'history')),
    CONSTRAINT spots_osm_type_check CHECK (osm_type IN ('node', 'way', 'relation'))
);

CREATE SEQUENCE public.spots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

ALTER SEQUENCE public.spots_id_seq OWNED BY public.spots.id;

CREATE TABLE public.stories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name character varying(200) NOT NULL,
    description character varying(2000),
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT stories_name_check CHECK (((char_length((name)::text) >= 1) AND (char_length((name)::text) <= 200)))
);

CREATE TABLE public.story_activities (
    story_id uuid NOT NULL,
    activity_id uuid NOT NULL
);

CREATE TABLE public.story_copies (
    source_story_id uuid NOT NULL,
    recipient_id uuid NOT NULL,
    copy_story_id uuid NOT NULL
);

CREATE TABLE public.story_sends (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    story_id uuid NOT NULL,
    recipient_id uuid NOT NULL,
    sent_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.tz_boundaries_source (
    only_row boolean DEFAULT true NOT NULL,
    name text NOT NULL,
    loaded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT tz_boundaries_source_only_row_check CHECK (only_row)
);

CREATE TABLE public.tz_parts (
    tzid text NOT NULL,
    geom public.geometry(Polygon,4326) NOT NULL
);

CREATE TABLE public.user_identities (
    user_id uuid NOT NULL,
    provider text NOT NULL,
    subject character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_identities_provider_check CHECK ((provider = ANY (ARRAY['google'::text, 'facebook'::text])))
);

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying(255) NOT NULL,
    password_hash character varying(255),
    last_seen_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    display_name character varying(255),
    country character(2),
    avatar_key text,
    avatar_content_type character varying(64),
    avatar_updated_at timestamp with time zone,
    email_verified boolean DEFAULT false NOT NULL,
    heatmap_cap double precision DEFAULT 8.0 NOT NULL,
    timezone text DEFAULT 'UTC'::text NOT NULL,
    is_admin boolean DEFAULT false NOT NULL,
    locale character varying(8),
    map_version bigint DEFAULT 0 NOT NULL,
    imports_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    deleted_at timestamp with time zone,
    last_export_ready_at timestamp with time zone,
    heat_point_caps integer[],
    web_seen_at timestamp with time zone,
    android_seen_at timestamp with time zone,
    android_build integer
);

ALTER TABLE ONLY public.admin_countries ALTER COLUMN id SET DEFAULT nextval('public.admin_countries_id_seq'::regclass);

ALTER TABLE ONLY public.admin_regions ALTER COLUMN id SET DEFAULT nextval('public.admin_regions_id_seq'::regclass);

ALTER TABLE ONLY public.bike_paths ALTER COLUMN id SET DEFAULT nextval('public.bike_paths_id_seq'::regclass);

ALTER TABLE ONLY public.jobs ALTER COLUMN id SET DEFAULT nextval('public.jobs_id_seq'::regclass);

ALTER TABLE ONLY public.spots ALTER COLUMN id SET DEFAULT nextval('public.spots_id_seq'::regclass);

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.activity_country
    ADD CONSTRAINT activity_country_pkey PRIMARY KEY (activity_id, country_id);

ALTER TABLE ONLY public.activity_photos
    ADD CONSTRAINT activity_photos_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.activity_region
    ADD CONSTRAINT activity_region_pkey PRIMARY KEY (activity_id, region_id);

ALTER TABLE ONLY public.activity_tile_mask_data
    ADD CONSTRAINT activity_tile_mask_data_pkey PRIMARY KEY (activity_id, zoom, tile_x, tile_y);

ALTER TABLE ONLY public.activity_tile_masks
    ADD CONSTRAINT activity_tile_masks_pkey PRIMARY KEY (activity_id, zoom, tile_x, tile_y);

ALTER TABLE ONLY public.admin_boundaries_source
    ADD CONSTRAINT admin_boundaries_source_pkey PRIMARY KEY (only_row);

ALTER TABLE ONLY public.admin_countries
    ADD CONSTRAINT admin_countries_adm0_a3_key UNIQUE (code);

ALTER TABLE ONLY public.admin_countries
    ADD CONSTRAINT admin_countries_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.admin_regions
    ADD CONSTRAINT admin_regions_adm1_code_key UNIQUE (overture_id);

ALTER TABLE ONLY public.admin_regions
    ADD CONSTRAINT admin_regions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.admin_tile_geoms
    ADD CONSTRAINT admin_tile_geoms_pkey PRIMARY KEY (layer, zoom, tile_x, tile_y, admin_id);

ALTER TABLE ONLY public.admin_tiles_built
    ADD CONSTRAINT admin_tiles_built_pkey PRIMARY KEY (layer, zoom, tile_x, tile_y);

ALTER TABLE ONLY public.auth_handoffs
    ADD CONSTRAINT auth_handoffs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.bike_paths
    ADD CONSTRAINT bike_paths_osm_id_key UNIQUE (osm_id);

ALTER TABLE ONLY public.bike_paths
    ADD CONSTRAINT bike_paths_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.connections
    ADD CONSTRAINT connections_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.connections
    ADD CONSTRAINT connections_provider_provider_user_id_key UNIQUE (provider, provider_user_id);

ALTER TABLE ONLY public.connections
    ADD CONSTRAINT connections_user_id_provider_key UNIQUE (user_id, provider);

ALTER TABLE ONLY public.daily_stats
    ADD CONSTRAINT daily_stats_pkey PRIMARY KEY (day, key);

ALTER TABLE ONLY public.email_verifications
    ADD CONSTRAINT email_verifications_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.exports
    ADD CONSTRAINT exports_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.fog_tiles
    ADD CONSTRAINT fog_tiles_pkey PRIMARY KEY (user_id, zoom, tile_x, tile_y);

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.password_resets
    ADD CONSTRAINT password_resets_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.privacy_zones
    ADD CONSTRAINT privacy_zones_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.r2_ops
    ADD CONSTRAINT r2_ops_pkey PRIMARY KEY (day, class);

ALTER TABLE ONLY public.received_origins
    ADD CONSTRAINT received_origins_pkey PRIMARY KEY (user_id, origin_id);

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.spot_captures
    ADD CONSTRAINT spot_captures_pkey PRIMARY KEY (user_id, spot_id);

ALTER TABLE ONLY public.spots
    ADD CONSTRAINT spots_osm_type_osm_id_key UNIQUE (osm_type, osm_id);

ALTER TABLE ONLY public.spots
    ADD CONSTRAINT spots_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.stories
    ADD CONSTRAINT stories_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.story_activities
    ADD CONSTRAINT story_activities_pkey PRIMARY KEY (story_id, activity_id);

ALTER TABLE ONLY public.story_copies
    ADD CONSTRAINT story_copies_pkey PRIMARY KEY (source_story_id, recipient_id);

ALTER TABLE ONLY public.story_sends
    ADD CONSTRAINT story_sends_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.story_sends
    ADD CONSTRAINT story_sends_story_id_recipient_id_key UNIQUE (story_id, recipient_id);

ALTER TABLE ONLY public.tz_boundaries_source
    ADD CONSTRAINT tz_boundaries_source_pkey PRIMARY KEY (only_row);

ALTER TABLE ONLY public.user_identities
    ADD CONSTRAINT user_identities_pkey PRIMARY KEY (provider, subject);

ALTER TABLE ONLY public.user_identities
    ADD CONSTRAINT user_identities_user_id_provider_key UNIQUE (user_id, provider);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);

CREATE UNIQUE INDEX idx_activities_dedupe ON public.activities USING btree (user_id, source, external_id) WHERE (external_id IS NOT NULL);

CREATE INDEX idx_activities_in_heatmap_window ON public.activities USING btree (started_at) WHERE in_heatmap_window;

CREATE INDEX idx_activities_spatial ON public.activities USING gist (trajectory);

CREATE INDEX idx_activities_split_group ON public.activities USING btree (split_group) WHERE (split_group IS NOT NULL);

CREATE INDEX idx_activities_type ON public.activities USING btree (user_id, activity_type);

CREATE INDEX idx_activities_user_pending ON public.activities USING btree (user_id) WHERE edit_pending;

CREATE INDEX idx_activities_user_recorded_start ON public.activities USING btree (user_id, COALESCE(recorded_started_at, started_at));

CREATE INDEX idx_activities_user_time ON public.activities USING btree (user_id, started_at DESC);

CREATE INDEX idx_activity_country_country ON public.activity_country USING btree (country_id);

CREATE INDEX idx_activity_photos_activity ON public.activity_photos USING btree (activity_id);

CREATE INDEX idx_activity_photos_image_key ON public.activity_photos USING btree (image_key);

CREATE INDEX idx_activity_photos_user ON public.activity_photos USING btree (user_id);

CREATE INDEX idx_activity_region_region ON public.activity_region USING btree (region_id);

CREATE INDEX idx_activity_tile_masks_tile ON public.activity_tile_masks USING btree (zoom, tile_x, tile_y);

CREATE INDEX idx_admin_countries_geom ON public.admin_countries USING gist (geom);

CREATE INDEX idx_admin_country_parts_country ON public.admin_country_parts USING btree (country_id);

CREATE INDEX idx_admin_country_parts_geom ON public.admin_country_parts USING gist (geom);

CREATE INDEX idx_admin_region_parts_geom ON public.admin_region_parts USING gist (geom);

CREATE INDEX idx_admin_region_parts_region ON public.admin_region_parts USING btree (region_id);

CREATE INDEX idx_admin_regions_country ON public.admin_regions USING btree (country_id);

CREATE INDEX idx_admin_regions_geom ON public.admin_regions USING gist (geom);

CREATE INDEX idx_bike_paths_geom ON public.bike_paths USING gist (geom);

CREATE INDEX idx_email_verifications_user ON public.email_verifications USING btree (user_id);

CREATE INDEX idx_exports_expiry ON public.exports USING btree (expires_at) WHERE (expires_at IS NOT NULL);

CREATE INDEX idx_exports_user ON public.exports USING btree (user_id, requested_at DESC);

CREATE INDEX idx_fog_dirty ON public.fog_tiles USING btree (user_id) WHERE dirty;

CREATE INDEX idx_jobs_runnable ON public.jobs USING btree (run_after, id) WHERE ((state)::text = 'pending'::text);

CREATE INDEX idx_jobs_user ON public.jobs USING btree (user_id, id);

CREATE INDEX idx_jobs_user_locked ON public.jobs USING btree (user_id, locked_at);

CREATE INDEX idx_password_resets_user ON public.password_resets USING btree (user_id);

CREATE INDEX idx_privacy_user ON public.privacy_zones USING btree (user_id);

CREATE INDEX idx_sessions_user ON public.sessions USING btree (user_id);

CREATE INDEX idx_spots_geom ON public.spots USING gist (geom);

CREATE INDEX idx_stories_user ON public.stories USING btree (user_id);

CREATE INDEX idx_story_activities_activity ON public.story_activities USING btree (activity_id);

CREATE INDEX idx_story_copies_copy ON public.story_copies USING btree (copy_story_id);

CREATE INDEX idx_story_sends_recipient ON public.story_sends USING btree (recipient_id);

CREATE INDEX idx_tz_parts_geom ON public.tz_parts USING gist (geom);

CREATE INDEX idx_users_deleted ON public.users USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.activity_country
    ADD CONSTRAINT activity_country_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.activity_country
    ADD CONSTRAINT activity_country_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.admin_countries(id);

ALTER TABLE ONLY public.activity_photos
    ADD CONSTRAINT activity_photos_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.activity_photos
    ADD CONSTRAINT activity_photos_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.activity_region
    ADD CONSTRAINT activity_region_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.activity_region
    ADD CONSTRAINT activity_region_region_id_fkey FOREIGN KEY (region_id) REFERENCES public.admin_regions(id);

ALTER TABLE ONLY public.activity_tile_mask_data
    ADD CONSTRAINT activity_tile_mask_data_activity_id_zoom_tile_x_tile_y_fkey FOREIGN KEY (activity_id, zoom, tile_x, tile_y) REFERENCES public.activity_tile_masks(activity_id, zoom, tile_x, tile_y) ON DELETE CASCADE;

ALTER TABLE ONLY public.activity_tile_masks
    ADD CONSTRAINT activity_tile_masks_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.admin_country_parts
    ADD CONSTRAINT admin_country_parts_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.admin_countries(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.admin_region_parts
    ADD CONSTRAINT admin_region_parts_region_id_fkey FOREIGN KEY (region_id) REFERENCES public.admin_regions(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.admin_regions
    ADD CONSTRAINT admin_regions_country_id_fkey FOREIGN KEY (country_id) REFERENCES public.admin_countries(id);

ALTER TABLE ONLY public.auth_handoffs
    ADD CONSTRAINT auth_handoffs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.connections
    ADD CONSTRAINT connections_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.email_verifications
    ADD CONSTRAINT email_verifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.exports
    ADD CONSTRAINT exports_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(id) ON DELETE SET NULL;

ALTER TABLE ONLY public.exports
    ADD CONSTRAINT exports_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.fog_tiles
    ADD CONSTRAINT fog_tiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.password_resets
    ADD CONSTRAINT password_resets_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.privacy_zones
    ADD CONSTRAINT privacy_zones_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.received_origins
    ADD CONSTRAINT received_origins_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.sessions
    ADD CONSTRAINT sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.spot_captures
    ADD CONSTRAINT spot_captures_spot_id_fkey FOREIGN KEY (spot_id) REFERENCES public.spots(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.spot_captures
    ADD CONSTRAINT spot_captures_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.stories
    ADD CONSTRAINT stories_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.story_activities
    ADD CONSTRAINT story_activities_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.story_activities
    ADD CONSTRAINT story_activities_story_id_fkey FOREIGN KEY (story_id) REFERENCES public.stories(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.story_copies
    ADD CONSTRAINT story_copies_copy_story_id_fkey FOREIGN KEY (copy_story_id) REFERENCES public.stories(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.story_copies
    ADD CONSTRAINT story_copies_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.story_copies
    ADD CONSTRAINT story_copies_source_story_id_fkey FOREIGN KEY (source_story_id) REFERENCES public.stories(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.story_sends
    ADD CONSTRAINT story_sends_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES public.users(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.story_sends
    ADD CONSTRAINT story_sends_story_id_fkey FOREIGN KEY (story_id) REFERENCES public.stories(id) ON DELETE CASCADE;

ALTER TABLE ONLY public.user_identities
    ADD CONSTRAINT user_identities_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;

INSERT INTO public.users (id, email, display_name, country, timezone)
VALUES ('22222222-2222-2222-2222-222222222222', 'demo-customer@holdmytrack.invalid', 'Demo User', 'US', 'America/New_York');

-- Where its history starts and ends, so ingest clips them as it would for any account (FR-8.1).
-- radius_m = 305 is the closest whole-meters value to 1000 ft (304.8 m).
INSERT INTO public.privacy_zones (user_id, name, center, radius_m)
SELECT '22222222-2222-2222-2222-222222222222', z.name, public.ST_SetSRID(public.ST_MakePoint(z.lon, z.lat), 4326)::public.geography, 305
FROM (VALUES
    ('Home',            41.388222, -81.739806),
    ('Eva''s school',   41.397861, -81.734556),
    ('Sonya''s school', 41.482333, -81.736833)
) AS z(name, lat, lon);
