use role falkordb_role;
create application package if not exists falkordb_app_pkg;
alter application package falkordb_app_pkg register version V1 using @falkordb_app.napp.app_stage;
grant install, develop on application package falkordb_app_pkg to role consumer_role;