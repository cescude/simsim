#include "mongoose.h"
#include "mext.h"

/* void mg_http_start_reply(struct mg_connection *c, int code, const char *msg, size_t msg) { */
/*   mg_printf(c, "HTTP/1.1 %d %s\r\n", */
/* 	    code, */
/*             mg_http_status_code_str(code)); */
/* } */

/* void mg_http_write_header(struct mg_connection *c, const char* header, size_t len) { */
/*   mg_printf(c, "%.*s\r\n", len, header); */
/* } */

/* void mg_http_finish_reply(struct mg_connection *c, const char* body, size_t len) { */
/*   mg_printf(c, "Content-Length: %d\r\n\r\n%.*s", len, len, body); */
/*   c->is_resp = 0; */
/* } */

void mg_finish_resp(struct mg_connection *c) {
  c->is_resp = 0;
}
