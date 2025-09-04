use role accountadmin;
create role if not exists falkordb_role;
grant role falkordb_role to role accountadmin;
grant create integration on account to role falkordb_role;
--grant create compute pool on account to role falkordb_role;
grant create warehouse on account to role falkordb_role;
grant create database on account to role falkordb_role;
grant create application package on account to role falkordb_role;
grant create application on account to role falkordb_role with grant option;
grant bind service endpoint on account to role falkordb_role;


use role falkordb_role;
create database if not exists falkordb_app;
use database falkordb_app;
create schema if not exists falkordb_app.napp;
create stage if not exists falkordb_app.napp.app_stage;
create image repository if not exists falkordb_app.napp.img_repo;
create warehouse if not exists wh_falkordb with warehouse_size='xsmall';


--  Create Consumer role and Grant Privileges
use role accountadmin;
create role if not exists consumer_role;
grant role consumer_role to role accountadmin;
create warehouse if not exists wh_consumer with warehouse_size='xsmall';
grant usage on warehouse wh_consumer to role consumer_role with grant option;
--grant imported privileges on database snowflake_sample_data to role consumer_role;
grant create database on account to role consumer_role;
grant bind service endpoint on account to role consumer_role with grant option;
grant create compute pool on account to role consumer_role;
grant create application on account to role consumer_role;

-- Get Image Repository URL
use role falkordb_role;
use database falkordb_app;
show image repositories in schema falkordb_app.napp;