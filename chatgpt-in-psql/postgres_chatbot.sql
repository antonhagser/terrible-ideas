ROLLBACK;
BEGIN;

CREATE EXTENSION IF NOT EXISTS http;

SET http.curlopt_timeout_msec = 60000;

---------------------------------------------------------------
-- 0. CONFIG – API key & model name
---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS openai_config (
                                             id          int  PRIMARY KEY CHECK (id = 1),
                                             api_key     text  NOT NULL,
                                             model_name  text  NOT NULL DEFAULT 'gpt-4o'
);

INSERT INTO openai_config (id, api_key)
VALUES (1, 'sk-REPLACE_ME')
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE VIEW v_openai_conf AS
SELECT api_key, model_name FROM openai_config WHERE id = 1;

---------------------------------------------------------------
-- 1. MESSAGE LOG
---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS messages (
                                        msg_id          bigserial PRIMARY KEY,
                                        conversation_id bigint     NOT NULL,
                                        role            text       NOT NULL CHECK (role IN ('user','assistant')),
                                        content         text       NOT NULL,
                                        created_at      timestamptz DEFAULT now(),
                                        content_tsv     tsvector   GENERATED ALWAYS AS
                                            (to_tsvector('simple', content)) STORED
);

CREATE INDEX IF NOT EXISTS ix_messages_conv_time
    ON messages (conversation_id, created_at DESC);

---------------------------------------------------------------
-- 2. LONG-TERM MEMORY
---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS conversation_memories (
                                                     conversation_id bigint PRIMARY KEY,
                                                     last_msg_id     bigint,
                                                     summary         text,
                                                     updated_at      timestamptz DEFAULT now()
);

---------------------------------------------------------------
-- 3. UTILS
---------------------------------------------------------------
CREATE OR REPLACE FUNCTION build_message_array(_conv bigint,
                                               _limit int DEFAULT 12)
    RETURNS json LANGUAGE sql IMMUTABLE AS
$$
SELECT COALESCE(
               (
                   SELECT json_agg(
                                  json_build_object('role', role, 'content', content)
                                  ORDER BY created_at
                          )
                   FROM (
                            SELECT role, content, created_at
                            FROM messages
                            WHERE conversation_id = _conv
                            ORDER BY created_at DESC
                            LIMIT _limit
                        ) sub
               ),
               '[]'::json
       );
$$;

---------------------------------------------------------------
-- 4. OPENAI CALL
---------------------------------------------------------------
CREATE OR REPLACE FUNCTION call_openai_chat(
    _msg_array     JSON,
    _system_prompt TEXT DEFAULT 'You are a helpful PostgreSQL bot.'
)
    RETURNS TEXT
    LANGUAGE plpgsql
AS $$
DECLARE
    v_api_key    TEXT;
    v_model_name TEXT;
    http_req     public.http_request;
    http_resp    public.http_response;
    reply_text   TEXT;
    msgs_jsonb   JSONB;
    payload      JSONB;
BEGIN
    -- 1. load credentials
    SELECT api_key, model_name
    INTO v_api_key, v_model_name
    FROM openai_config
    WHERE id = 1;

    -- 2. assemble messages array
    msgs_jsonb :=
            jsonb_build_array(
                    jsonb_build_object('role','system','content',_system_prompt)
            ) || _msg_array::jsonb;

    -- 3. chat payload
    payload :=
            jsonb_build_object(
                    'model',       v_model_name,
                    'messages',    msgs_jsonb,
                    'temperature', 0.7
            );

    -- 4. construct http_request composite
    http_req := ROW(
        'POST'::http_method,
        'https://api.openai.com/v1/chat/completions',
        ARRAY[
            http_header('Content-Type', 'application/json'),
            http_header('Authorization', 'Bearer ' || v_api_key)
            ]::public.http_header[],
        'application/json',
        payload::text
        )::public.http_request;

    -- 5. fire request
    SELECT * INTO http_resp
    FROM http(http_req);

    -- 6. handle response
    IF http_resp.status BETWEEN 200 AND 299 THEN
        reply_text :=
                (http_resp.content::json)
                    -> 'choices' -> 0 -> 'message' ->> 'content';
        RETURN reply_text;
    ELSE
        RAISE WARNING 'OpenAI error %: %',
            http_resp.status,
            left(http_resp.content, 200);
        RETURN format('[OpenAI error %s]', http_resp.status);
    END IF;
END;
$$;

---------------------------------------------------------------
-- 5. TRIGGER: auto-reply
---------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_auto_reply()
    RETURNS trigger
    LANGUAGE plpgsql
AS $$
DECLARE
    assistant_reply text;
BEGIN
    -- only fire on user messages
    IF (TG_OP = 'INSERT' AND NEW.role = 'user') THEN
        assistant_reply := call_openai_chat(
                build_message_array(NEW.conversation_id)
                           );

        INSERT INTO messages (conversation_id, role, content)
        VALUES (NEW.conversation_id, 'assistant', assistant_reply);
    END IF;

    RETURN NEW;
END;
$$;

-- rebind the trigger
DROP TRIGGER IF EXISTS on_user_message ON messages;
CREATE TRIGGER on_user_message
    AFTER INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION trg_auto_reply();

---------------------------------------------------------------
-- 6. TRIGGER: summarise long threads
---------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_condense()
    RETURNS trigger LANGUAGE plpgsql AS
$$
DECLARE
    char_sum  bigint;
    tok_est   int;
    last_id   bigint;
    sum_text  text;
BEGIN
    SELECT sum(length(content)) INTO char_sum
    FROM messages
    WHERE conversation_id = NEW.conversation_id;

    tok_est := ceil(char_sum / 3.5);   -- ≈ tokens

    IF tok_est < 1500 THEN
        RETURN NEW;
    END IF;

    SELECT max(msg_id) INTO last_id
    FROM messages
    WHERE conversation_id = NEW.conversation_id;

    sum_text :=
            call_openai_chat(
                    build_message_array(NEW.conversation_id, 60),
                    'Summarise the entire conversation so far in ≤150 words.'
            );

    INSERT INTO conversation_memories
    (conversation_id, last_msg_id, summary)
    VALUES (NEW.conversation_id, last_id, sum_text)
    ON CONFLICT (conversation_id)
        DO UPDATE SET
                      last_msg_id = EXCLUDED.last_msg_id,
                      summary     = EXCLUDED.summary,
                      updated_at  = now();

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS maybe_summarise ON messages;
CREATE TRIGGER maybe_summarise
    AFTER INSERT ON messages
    FOR EACH ROW EXECUTE FUNCTION trg_condense();

---------------------------------------------------------------
-- 7. CONVENIENCE VIEW
---------------------------------------------------------------
CREATE OR REPLACE VIEW chat_view AS
SELECT conversation_id, role, content, created_at
FROM messages
ORDER BY conversation_id, created_at;

COMMIT;

---------------------------------------------------------------
-- 8. SEND AND RECEIVE
---------------------------------------------------------------
CREATE OR REPLACE FUNCTION send_message(
    _conv_id  bigint,
    _content  text
)
    RETURNS TABLE (
                      role       text,
                      content    text,
                      created_at timestamptz
                  )
    LANGUAGE plpgsql
AS $$
BEGIN
    -- 1) insert the user message
    INSERT INTO messages (conversation_id, role, content)
    VALUES (_conv_id, 'user', _content);

    -- 2) return the entire thread, aliasing to avoid ambiguity
    RETURN QUERY
        SELECT cv.role,
               cv.content,
               cv.created_at
        FROM   chat_view AS cv
        WHERE  cv.conversation_id = _conv_id
        ORDER  BY cv.created_at;
END;
$$;
