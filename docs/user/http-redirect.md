# HTTP Redirects

The [HTTPRoute][] resource can issue redirects to clients or rewrite paths sent upstream using filters. Note that
HTTPRoute rules cannot use both filter types at once. Currently, Envoy Gateway only supports __core__
[HTTPRoute filters][] which consist of `RequestRedirect` and `RequestHeaderModifier` at the time of this writing. To
learn more about HTTP routing, refer to the [Gateway API documentation][].

Follow the steps from the [Secure Gateways](secure-gateways.md) to install Envoy Gateway and the example manifest. Do not
proceed until you can curl the example backend from the Quickstart guide using HTTPS.

## Redirects
Redirects return HTTP 3XX responses to a client, instructing it to retrieve a different resource. A
[`RequestRedirect` filter][req_filter] instructs Gateways to emit a redirect response to requests that match the rule.
For example, to issue a permanent redirect (301) from HTTP to HTTPS, configure `requestRedirect.statusCode=301` and
`requestRedirect.scheme="https"`:

```shell
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: http-to-https-filter-redirect
spec:
  parentRefs:
    - name: eg
  hostnames:
    - redirect.example
  rules:
    - filters:
      - type: RequestRedirect
        requestRedirect:
          scheme: https
          statusCode: 301
          hostname: www.example.com
          port: 8443
      backendRefs:
      - name: httpbin
        port: 80
EOF
```

__Note:__ `301` (default) and `302` are the only supported statusCodes.

The HTTPRoute status should indicate that it has been accepted and is bound to the example Gateway.

```shell
kubectl get httproute/http-to-https-filter-redirect -o yaml
```

Get the Gateway's address:

```shell
export GATEWAY_HOST=$(kubectl get gateway/eg -o jsonpath='{.status.addresses[0].value}')
```

Querying `redirect.example/get` should result in a `301` response from the example Gateway and redirecting to the
configured redirect hostname.

```console
$ curl -L -vvv --header "Host: redirect.example" "http://${GATEWAY_HOST}:8080/get"
...
< HTTP/1.1 301 Moved Permanently
< location: https://www.example.com:8443/get
...
```

If you followed the steps in the [Secure Gateways](secure-gateways.md) guide, you should be able to curl the redirect
location.

## Path Redirects
Path redirects use an HTTP Path Modifier to replace either entire paths or path prefixes. For example, the HTTPRoute
below will issue a 302 redirect to all `path.redirect.example` requests whose path begins with `/get` to `/status/200`.

```shell
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: http-filter-path-redirect
spec:
  parentRefs:
    - name: eg
  hostnames:
    - path.redirect.example
  rules:
    - matches:
      - path:
          type: PathPrefix
          value: /get
      filters:
      - type: RequestRedirect
        requestRedirect:
          path:
            type: ReplaceFullPath
            replaceFullPath: /status/200
          statusCode: 302
      backendRefs:
      - name: httpbin
        port: 80
EOF
```

The HTTPRoute status should indicate that it has been accepted and is bound to the example Gateway.

```shell
kubectl get httproute/http-filter-path-redirect -o yaml
```

Querying `path.redirect.example` should result in a `302` response from the example Gateway and a redirect location
containing the configured redirect path.

Query the `path.redirect.example` host:

```shell
curl -vvv --header "Host: path.redirect.example" "http://${GATEWAY_HOST}:8080/get"
```

You should receive a `302` with a redirect location of `http://path.redirect.example/status/200`.

[HTTPRoute]: https://gateway-api.sigs.k8s.io/api-types/httproute/
[HTTPRoute filters]: https://gateway-api.sigs.k8s.io/references/spec/#gateway.networking.k8s.io/v1beta1.HTTPRouteFilter
[Gateway API documentation]: https://gateway-api.sigs.k8s.io/
[req_filter]: https://gateway-api.sigs.k8s.io/references/spec/#gateway.networking.k8s.io/v1beta1.HTTPRequestRedirectFilter
