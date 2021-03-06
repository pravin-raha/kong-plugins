local OXD_SCHEMA = {
    primary_key = { "id" },
    table = "oxds",
    fields = {
        id = { type = "id", dao_insert_value = true },
        consumer_id = { type = "id", required = true, foreign = "consumers:id" },
        oxd_id = { type = "string", required = true },
        op_host = { type = "string", required = true },
        client_id = { type = "string" },
        client_secret = { type = "string" },
        authorization_redirect_uri = { type = "string", required = true},
        oxd_port = { type = "string", required = true },
        oxd_host = { type = "string", required = true },
        scope = { type = "string", required = true },
        created_at = { type = "timestamp", immutable = true, dao_insert_value = true },
    },
    marshall_event = function(self, t)
        return { id = t.id, consumer_id = t.consumer_id, oxd_id = t.oxd_id, client_id = t.client_id }
    end
}

return { oxds = OXD_SCHEMA }