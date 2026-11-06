#!/usr/bin/env python3
"""Offline route metadata contract using isolated catalogs and route selection."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

binary = Path(os.environ.get('PROXYPILOT_BIN', Path(__file__).parents[1] / '.build/debug/proxypilot')).resolve()
with tempfile.TemporaryDirectory(prefix='pp-route-metadata-') as temp:
    root = Path(temp)
    config = root / 'proxypilot'
    catalogs = config / 'catalogs'
    catalogs.mkdir(parents=True)
    env = dict(os.environ, XDG_CONFIG_HOME=str(root), PROXYPILOT_SECRETS_DIR=str(root / 'secrets'))
    def status(provider, model, endpoint, rows):
        (config / 'route.json').write_text(json.dumps(dict(provider=provider, model=model, port=59999, updatedAt='2026-11-06T12:00:00Z')))
        key = hashlib.sha256((provider + '\n' + endpoint.rstrip('/')).encode()).hexdigest()
        (catalogs / (key + '.json')).write_text(json.dumps(dict(models=rows, fetchedAt=time.time()-978307200)))
        result = subprocess.run([str(binary), 'route', 'status', '--json'], env=env, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)
    result = status('openrouter', 'fixture:exacto', 'https://openrouter.ai/api/v1', [dict(id='fixture', contextLength=32000, maximumOutputTokens=2048, inputModalities=['text','image'], outputModalities=['text'])])
    assert result['model'] == 'fixture:exacto' and result['modalities']['image_support'] == 'supported'
    assert result['limits'] == dict(context=32000, output=2048)
    assert result['metadata_provenance'] == 'provider_catalog' and result['metadata_fetched_at']
    result = status('deepseek', 'deepseek-chat', 'https://api.deepseek.com/v1', [dict(id='deepseek-chat')])
    assert result['limits']['context'] == 1000000 and result['pricing']['input_per_million'] is not None
    assert result['metadata_provenance'] == 'provider_catalog_with_known_fallback'
    result = status('deepseek', 'deepseek-chat', 'https://api.deepseek.com/v1', [dict(id='unrelated')])
    assert result['limits']['context'] == 1000000
    assert result['metadata_provenance'] == 'provider_known_catalog' and result['metadata_fetched_at'] is None
print('Route metadata CLI contract passed: exacto capabilities, known fallback, source provenance.')
