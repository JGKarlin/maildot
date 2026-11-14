#include "PinnedHTTP.h"
#include <curl/curl.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>

int bridge_address_is_public(const char *text) {
    struct in_addr v4;
    if (inet_pton(AF_INET,text,&v4) == 1) {
        unsigned a = ntohl(v4.s_addr), first = a >> 24, second = (a >> 16) & 255;
        if (first == 0 || first == 10 || first == 127 || first >= 224 ||
            (first == 100 && second >= 64 && second <= 127) ||
            (first == 169 && second == 254) || (first == 172 && second >= 16 && second <= 31) ||
            (first == 192 && (second == 168 || (a & 0xffffff00) == 0xc0000000 ||
                             (a & 0xffffff00) == 0xc0000200 || (a & 0xffffff00) == 0xc0586300)) ||
            (a & 0xfffe0000) == 0xc6120000 || (a & 0xffffff00) == 0xc6336400 ||
            (a & 0xffffff00) == 0xcb007100) return 0;
        return 1;
    }
    struct in6_addr v6;
    if (inet_pton(AF_INET6,text,&v6) != 1) return 0;
    const unsigned char *b = v6.s6_addr;
    if ((b[0] & 0xe0) != 0x20) return 0;
    if (b[0] == 0x20 && b[1] == 0x01 && ((b[2] < 2) || (b[2] == 0x0d && b[3] == 0xb8))) return 0;
    if (b[0] == 0x20 && b[1] == 0x02) return 0; // 6to4 embeds an IPv4 destination.
    if (b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0) return 0; // documentation /20
    return 1;
}

struct sink { unsigned char *bytes; size_t size, capacity; };
static size_t receive_body(char *bytes,size_t size,size_t count,void *context) {
    struct sink *sink = context;
    if (count != 0 && size > sink->capacity / count) return 0;
    size_t length = size * count;
    // A reply longer than the buffer is cut short, not treated as a failed transfer: the status code is
    // what decides delivery, and a refusal here would make a delivered event be sent again.
    size_t room = sink->capacity - sink->size;
    size_t kept = length < room ? length : room;
    memcpy(sink->bytes + sink->size,bytes,kept); sink->size += kept;
    return length;
}
static void initialize_curl(void *context) { (void)context; curl_global_init(CURL_GLOBAL_DEFAULT); }

int bridge_https_post(const char *url,const unsigned char *body,size_t length,
                      const char *event_id,const char *timestamp,const char *signature,
                      const char *subscription_id,unsigned char *response,size_t capacity,
                      size_t *response_length,long *status) {
    static dispatch_once_t once;
    dispatch_once_f(&once,NULL,initialize_curl);
    *response_length = 0; *status = 0;
    CURLU *parsed = curl_url();
    if (!parsed) return 1;
    char *host = NULL, *scheme = NULL;
    CURL *handle = NULL;
    struct addrinfo *addresses = NULL;
    struct curl_slist *resolve = NULL, *headers = NULL;
    int result = 1;
    if (curl_url_set(parsed,CURLUPART_URL,url,0) != CURLUE_OK ||
        curl_url_get(parsed,CURLUPART_HOST,&host,0) != CURLUE_OK ||
        curl_url_get(parsed,CURLUPART_SCHEME,&scheme,0) != CURLUE_OK || strcmp(scheme,"https")) goto cleanup;
    struct addrinfo hints = {0}; hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host,NULL,&hints,&addresses) != 0 || !addresses) goto cleanup;
    char selected[INET6_ADDRSTRLEN] = {0};
    for (struct addrinfo *entry = addresses; entry; entry = entry->ai_next) {
        char text[INET6_ADDRSTRLEN]; const void *address;
        if (entry->ai_family == AF_INET) address = &((struct sockaddr_in *)entry->ai_addr)->sin_addr;
        else if (entry->ai_family == AF_INET6) address = &((struct sockaddr_in6 *)entry->ai_addr)->sin6_addr;
        else goto cleanup;
        if (!inet_ntop(entry->ai_family,address,text,sizeof(text)) || !bridge_address_is_public(text)) goto cleanup;
        if (!selected[0]) strlcpy(selected,text,sizeof(selected));
    }
    char pinned[512];
    if (snprintf(pinned,sizeof(pinned),strchr(selected,':') ? "%s:443:[%s]" : "%s:443:%s",host,selected) >= sizeof(pinned)) goto cleanup;
    // CURLOPT_RESOLVE pins the checked address; libcurl keeps original SNI/Host/TLS checks.
    resolve = curl_slist_append(NULL,pinned);
    headers = curl_slist_append(NULL,"Content-Type: application/json");
    const char *names[] = {"webhook-id","webhook-timestamp","webhook-signature","X-MCP-Subscription-Id"};
    const char *values[] = {event_id,timestamp,signature,subscription_id};
    for (int i=0;i<4;i++) {
        char header[1024];
        if (strpbrk(values[i],"\r\n") || snprintf(header,sizeof(header),"%s: %s",names[i],values[i]) >= sizeof(header)) goto cleanup;
        struct curl_slist *next = curl_slist_append(headers,header);
        if (!next) goto cleanup;
        headers = next;
    }
    if (!resolve || !headers || !(handle = curl_easy_init())) goto cleanup;
    struct sink sink = {response,0,capacity};
    curl_easy_setopt(handle,CURLOPT_URL,url);
    curl_easy_setopt(handle,CURLOPT_RESOLVE,resolve);
    curl_easy_setopt(handle,CURLOPT_PROXY,"");
    curl_easy_setopt(handle,CURLOPT_PROTOCOLS_STR,"https");
    curl_easy_setopt(handle,CURLOPT_FOLLOWLOCATION,0L);
    curl_easy_setopt(handle,CURLOPT_SSL_VERIFYPEER,1L);
    curl_easy_setopt(handle,CURLOPT_SSL_VERIFYHOST,2L);
    curl_easy_setopt(handle,CURLOPT_CONNECTTIMEOUT,5L);
    curl_easy_setopt(handle,CURLOPT_TIMEOUT,10L);
    curl_easy_setopt(handle,CURLOPT_NOSIGNAL,1L);
    curl_easy_setopt(handle,CURLOPT_HTTPHEADER,headers);
    curl_easy_setopt(handle,CURLOPT_POSTFIELDS,body);
    curl_easy_setopt(handle,CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)length);
    curl_easy_setopt(handle,CURLOPT_WRITEFUNCTION,receive_body);
    curl_easy_setopt(handle,CURLOPT_WRITEDATA,&sink);
    result = (int)curl_easy_perform(handle);
    if (result == CURLE_OK) {
        curl_easy_getinfo(handle,CURLINFO_RESPONSE_CODE,status); *response_length = sink.size;
    }
cleanup:
    if (handle) curl_easy_cleanup(handle);
    if (addresses) freeaddrinfo(addresses);
    curl_slist_free_all(resolve); curl_slist_free_all(headers);
    curl_free(host); curl_free(scheme); curl_url_cleanup(parsed);
    return result;
}
