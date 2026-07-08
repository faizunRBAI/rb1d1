import os
import logging
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker, DeclarativeBase

log = logging.getLogger(__name__)
_raw_db_url = os.getenv('DATABASE_URL', '')
DATABASE_URL = _raw_db_url if '+aiomysql' in _raw_db_url else _raw_db_url.replace('mysql://', 'mysql+aiomysql://')

engine = create_async_engine(DATABASE_URL, echo=False) if DATABASE_URL else None
AsyncSessionLocal = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False) if engine else None

class Base(DeclarativeBase):
    pass

async def connect_db():
    # Fail-soft: a DB outage shouldn't take the whole app down at startup.
    # /health should still respond so the platform can report status.
    if engine is None:
        log.warning('DATABASE_URL not set — running without DB')
        return
    try:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        log.info('MySQL connected')
    except Exception as e:
        log.error('MySQL connect failed (continuing): %s', e)

async def disconnect_db():
    if engine is not None:
        await engine.dispose()
