# ChatGPT in PostgreSQL

> **Warning:** This project is a **technically working yet fundamentally absurd** experiment. Proceed only if you enjoy confusing your DBAs and scaring your production teams.

A proof-of-concept that embeds an OpenAI chat model (e.g. GPT-4) directly into your database. Yes, you read that right: **your database now talks back**.

## 🛠️ Setup

Load the SQL script into your database:

```sql
-- from psql or your SQL client
\i chatgpt-in-psql/postgres_chatbot.sql
```

Ensure the `http` extension is installed (superuser required):

```sql
CREATE EXTENSION IF NOT EXISTS http;
```

## 🔑 Configuration

Add your OpenAI API key and select a model:

```sql
UPDATE openai_config
SET api_key    = 'sk-REPLACE_ME',
    model_name = 'gpt-4o'
WHERE id = 1;
```

## 🚀 Usage

### 1. One-line chat

Let Postgres handle your chit-chat:

```sql
SELECT *
FROM send_message(42, 'Hello, database overlord!');
```

* **42** is your `conversation_id` — pick any integer to group messages.

### 2. Manual mode

```sql
-- Send a message
INSERT INTO messages (conversation_id, role, content)
VALUES (42, 'user', 'Tell me a joke about SQL servers.');

-- Read the transcript
SELECT *
FROM chat_view
WHERE conversation_id = 42
ORDER BY created_at;
```

### 3. Summaries

```sql
SELECT *
FROM conversation_memories
WHERE conversation_id = 42;
```

Summaries are generated once a thread exceeds \~1500 tokens.

## 🤪 Why This Is Terrible

* **Latency:** Each user message triggers an HTTP call.
* **Scalability:** Your database is now a chat client.
* **Support:** You’re on your own when chaos ensues.

---

> *Powered by reckless curiosity and a complete disregard for sane architecture decisions.*
