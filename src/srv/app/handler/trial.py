import re
import sqlite3

from bottle import abort, get, post, put, request, response

from app.data.db import sqlite as db


TRIAL_REPORTING_TIMEOUT = 60

ACTIVE_TRIAL_CONDITION = """\
size is null and period is null and (strftime('%s', 'now') - ts < ?)\
"""

RECENT_TRIAL_CONDITION = """\
size is not null and period is not null and (strftime('%s', 'now') - ts < ?)\
"""

CAST_TRUE = {'1', 'true', 'on'}
CAST_FALSE = {'0', 'false', 'off', ''}
CAST_VALUES = CAST_TRUE | CAST_FALSE


def clean_active():
    active_arg = request.query.active.lower()

    if active_arg not in CAST_VALUES:
        abort(400, 'Bad request')

    return active_arg in CAST_TRUE


def clean_period():
    if not request.query.period:
        return None

    period_match = re.fullmatch(r'(\d+)(m|h)?', request.query.period.lower())

    if not period_match:
        abort(400, 'Bad request')

    (period_value, period_unit) = period_match.groups()

    period_seconds = int(period_value)

    if period_unit == 'm':
        period_seconds *= 60
    elif period_unit == 'h':
        period_seconds *= 3600

    return period_seconds


def clean_limit():
    if not request.query.limit:
        return None

    try:
        return int(request.query.limit)
    except ValueError:
        abort(400, 'Bad request')


def build_where_clause():
    where = ''
    args = []

    if clean_active():
        where = f'where ({ACTIVE_TRIAL_CONDITION})'
        args.append(TRIAL_REPORTING_TIMEOUT)

    if (period := clean_period()) is not None:
        where += ' or ' if where else 'where '
        where += f'({RECENT_TRIAL_CONDITION})'
        args.append(period)

    return (where, args)


@get('/dashboard/trial/')
def list_trials():
    (where, args) = build_where_clause()

    limit = '' if (limit_value := clean_limit()) is None else f'limit {limit_value}'

    with db.client.connect() as conn:
        cursor = conn.execute(f"select * from trial {where} order by ts desc {limit}", args)

        names = [column[0] for column in cursor.description]

        results = [
            dict(zip(names, row))
            for row in cursor
        ]

    return {
        'selected': results,
        'count': len(results),
    }


@get('/dashboard/trial/stats')
def stat_trials():
    with db.client.connect() as conn:
        (total_count,) = conn.execute("""\
            select count(1) from trial
            where size is not null and period is not null
        """).fetchone()

        where = "where bucket between 2 and 9" if total_count > 8 else ""

        (stat_mean, stat_count) = conn.execute(f"""\
            select avg(rate),
                   count(1)

            from (
                select rate,
                       ntile(10) over (order by rate) as bucket

                from (
                    select 1000000.0 * size / period as rate from trial
                    where size is not null and period is not null
                )
            )

            {where}
        """).fetchone()

    return {
        'total_count': total_count,
        'stat_count': stat_count,
        'stat_mean': stat_mean,
    }


@post('/dashboard/trial/')
def create_trial():
    if request.forms:
        raise NotImplementedError

    (where, args) = build_where_clause()

    if where:
        query = f"""\
            insert into trial (ts)

            select * from (values (strftime('%s', 'now')))
            where not exists (select 1 from trial {where} limit 1)

            returning ts
        """
    else:
        query = "insert into trial default values returning ts"

    with db.client.connect() as conn:
        try:
            cursor = conn.execute(query, args)
        except sqlite3.IntegrityError:
            ts = None
        else:
            (ts,) = cursor.fetchone() or (None,)

    response.status = 409 if ts is None else 201

    return {
        'inserted': None if ts is None else {'ts': ts},
    }


@put('/dashboard/trial/<ts:int>')
def upsert_trial(ts):
    try:
        values = [int(arg) for arg in (request.forms.size,
                                       request.forms.period)]
    except ValueError:
        abort(400, 'Bad request')

    with db.client.connect() as conn:
        conn.execute("""\
            insert into trial values (?, ?, ?)
            on conflict (ts) do update set size=excluded.size, period=excluded.period
        """, [ts] + values)

    response.status = 204
