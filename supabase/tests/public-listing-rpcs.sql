\set ON_ERROR_STOP on
-- Synthetic contract tests based on exact production pg_get_functiondef/ACL
-- metadata inspected read-only on 2026-11-16. No production rows are used.
do $r$ begin create role anon nologin; exception when duplicate_object then null; end $r$;
do $r$ begin create role authenticated nologin; exception when duplicate_object then null; end $r$;

create table public.service_requests(id bigint primary key,title text,description text,city text,created_at timestamptz,phone text,contact_public boolean,image_urls text[],status text);
create table public.job_posts(id bigint primary key,title text,description text,city text,created_at timestamptz,job_type text,work_nature text,phone text,contact_public boolean,image_urls text[],status text);
create table public.real_estate_posts(id bigint primary key,title text,property_type text,listing_type text,description text,city text,created_at timestamptz,price numeric,size numeric,rooms integer,phone text,contact_public boolean,image_urls text[],status text);
create table public.market_posts(id bigint primary key,created_at timestamptz,title text,description text,category text,price numeric,city text,listing_type text,phone text,contact_public boolean,image_urls text[],status text);

create function public.public_service_requests()
returns table(id bigint,title text,description text,city text,created_at timestamptz,phone text,image_urls text[])
language sql stable security definer set search_path to ''
as $f$ select s.id,s.title,s.description,s.city,s.created_at,case when s.contact_public then s.phone else null end,s.image_urls from public.service_requests s where s.status='approved' order by s.created_at desc; $f$;
create function public.public_job_posts()
returns table(id bigint,title text,description text,city text,created_at timestamptz,job_type text,work_nature text,phone text,image_urls text[])
language sql stable security definer set search_path to ''
as $f$ select j.id,j.title,j.description,j.city,j.created_at,j.job_type,j.work_nature,case when j.contact_public then j.phone else null end,j.image_urls from public.job_posts j where j.status='approved' order by j.created_at desc; $f$;
create function public.public_real_estate_posts()
returns table(id bigint,title text,property_type text,listing_type text,description text,city text,created_at timestamptz,price numeric,size numeric,rooms integer,phone text,image_urls text[])
language sql stable security definer set search_path to ''
as $f$ select r.id,r.title,r.property_type,r.listing_type,r.description,r.city,r.created_at,r.price,r.size,r.rooms,case when r.contact_public then r.phone else null end,r.image_urls from public.real_estate_posts r where r.status='approved' order by r.created_at desc; $f$;
create function public.public_market_posts()
returns table(id bigint,created_at timestamptz,title text,description text,category text,price numeric,city text,listing_type text,phone text,image_urls text[])
language sql stable security definer set search_path to ''
as $f$ select m.id,m.created_at,m.title,m.description,m.category,m.price,m.city,m.listing_type,case when m.contact_public then m.phone else null end,m.image_urls from public.market_posts m where m.status='approved' order by m.created_at desc; $f$;

-- Minimal ACL-only stand-ins for the two observed overloads.
create function public.record_site_visit() returns void language sql security definer set search_path to '' as $f$ select; $f$;
create function public.record_site_visit(uuid) returns void language sql security definer set search_path to '' as $f$ select; $f$;

revoke all on function public.public_service_requests() from public,anon,authenticated;
revoke all on function public.public_job_posts() from public,anon,authenticated;
revoke all on function public.public_real_estate_posts() from public,anon,authenticated;
revoke all on function public.public_market_posts() from public,anon,authenticated;
grant execute on function public.public_service_requests(),public.public_job_posts(),public.public_real_estate_posts(),public.public_market_posts() to anon,authenticated;
revoke all on function public.record_site_visit() from public,anon,authenticated;
grant execute on function public.record_site_visit() to anon,authenticated;
revoke all on function public.record_site_visit(uuid) from public,anon,authenticated;

insert into public.service_requests values
(1,'public','d','Sfax',now(),'20000001',true,'{}','approved'),
(2,'private','d','Sfax',now()-interval '1 minute','20000002',false,'{}','approved'),
(3,'pending','d','Sfax',now(),'20000003',true,'{}','pending');
insert into public.job_posts values
(1,'public','d','Sfax',now(),'full-time','onsite','21000001',true,'{}','approved'),
(2,'private','d','Sfax',now()-interval '1 minute','21000002',false,'{}','approved'),
(3,'pending','d','Sfax',now(),'full-time','onsite','21000003',true,'{}','pending');
insert into public.real_estate_posts values
(1,'public','flat','rent','d','Sfax',now(),500,90,3,'22000001',true,'{}','approved'),
(2,'private','flat','rent','d','Sfax',now()-interval '1 minute',500,90,3,'22000002',false,'{}','approved'),
(3,'pending','flat','rent','d','Sfax',now(),500,90,3,'22000003',true,'{}','pending');
insert into public.market_posts values
(1,now(),'public','d','home',50,'Sfax','sale','23000001',true,'{}','approved'),
(2,now()-interval '1 minute','private','d','home',50,'Sfax','sale','23000002',false,'{}','approved'),
(3,now(),'pending','d','home',50,'Sfax','sale','23000003',true,'{}','pending');

do $acl$
begin
 if not has_function_privilege('anon','public.public_service_requests()','EXECUTE')
 or not has_function_privilege('authenticated','public.public_service_requests()','EXECUTE')
 or not has_function_privilege('anon','public.public_job_posts()','EXECUTE')
 or not has_function_privilege('anon','public.public_real_estate_posts()','EXECUTE')
 or not has_function_privilege('anon','public.public_market_posts()','EXECUTE')
 then raise exception 'Public listing RPC execute grant missing'; end if;
 if has_function_privilege('anon','public.record_site_visit(uuid)','EXECUTE')
 or has_function_privilege('authenticated','public.record_site_visit(uuid)','EXECUTE')
 then raise exception 'Legacy UUID visit overload is client-executable'; end if;
 if not has_function_privilege('anon','public.record_site_visit()','EXECUTE')
 then raise exception 'No-argument visit RPC is not executable by anon'; end if;
end $acl$;

set role anon;
do $anon$
declare n integer; p text;
begin
 select count(*) into n from public.public_service_requests(); if n<>2 then raise exception 'anon services status filter failed'; end if;
 select phone into p from public.public_service_requests() where id=2; if p is not null then raise exception 'anon service phone leaked'; end if;
 select count(*) into n from public.public_job_posts(); if n<>2 then raise exception 'anon jobs status filter failed'; end if;
 select phone into p from public.public_job_posts() where id=2; if p is not null then raise exception 'anon job phone leaked'; end if;
 select count(*) into n from public.public_real_estate_posts(); if n<>2 then raise exception 'anon realty status filter failed'; end if;
 select phone into p from public.public_real_estate_posts() where id=2; if p is not null then raise exception 'anon realty phone leaked'; end if;
 select count(*) into n from public.public_market_posts(); if n<>2 then raise exception 'anon market status filter failed'; end if;
 select phone into p from public.public_market_posts() where id=2; if p is not null then raise exception 'anon market phone leaked'; end if;
end $anon$;
reset role;

set role authenticated;
do $auth$
declare n integer; p text;
begin
 select count(*) into n from public.public_service_requests(); if n<>2 then raise exception 'authenticated services status filter failed'; end if;
 select phone into p from public.public_service_requests() where id=2; if p is not null then raise exception 'authenticated service phone leaked'; end if;
 select count(*) into n from public.public_job_posts(); if n<>2 then raise exception 'authenticated jobs status filter failed'; end if;
 select phone into p from public.public_job_posts() where id=2; if p is not null then raise exception 'authenticated job phone leaked'; end if;
 select count(*) into n from public.public_real_estate_posts(); if n<>2 then raise exception 'authenticated realty status filter failed'; end if;
 select phone into p from public.public_real_estate_posts() where id=2; if p is not null then raise exception 'authenticated realty phone leaked'; end if;
 select count(*) into n from public.public_market_posts(); if n<>2 then raise exception 'authenticated market status filter failed'; end if;
 select phone into p from public.public_market_posts() where id=2; if p is not null then raise exception 'authenticated market phone leaked'; end if;
end $auth$;
reset role;

drop function public.record_site_visit(uuid);
drop function public.record_site_visit();
drop function public.public_service_requests();
drop function public.public_job_posts();
drop function public.public_real_estate_posts();
drop function public.public_market_posts();
drop table public.service_requests,public.job_posts,public.real_estate_posts,public.market_posts;
