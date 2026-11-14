#include <stddef.h>
// No redirects, proxies or DNS re-resolution; TLS still verifies the URL hostname.
int bridge_address_is_public(const char *address);
int bridge_https_post(const char *url, const unsigned char *body, size_t length,
                      const char *event_id, const char *timestamp, const char *signature,
                      const char *subscription_id, unsigned char *response,
                      size_t capacity, size_t *response_length, long *status);
