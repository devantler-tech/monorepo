#ifndef DESKTOP_APP_LIFECYCLE_H
#define DESKTOP_APP_LIFECYCLE_H
int desktop_app_pids(const char *bundle_id, const char *app_path, int *pids, int capacity);
int desktop_app_request_quit(const char *bundle_id, const char *app_path);
void desktop_app_pump(void);
#endif
