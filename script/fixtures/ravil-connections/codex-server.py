#!/usr/bin/env python3
import json, sys
if len(sys.argv)>1 and sys.argv[1]=="mcp":
    print("[]"); sys.exit(0)

def emit(value):
    print(json.dumps(value), flush=True)

def result(request, value):
    emit({'id': request['id'], 'result': value})

last_text=''
for line in sys.stdin:
    request = json.loads(line)
    method = request.get('method')
    if 'id' not in request:
        continue
    if method == 'initialize':
        result(request, {'userAgent': 'ravil-test'})
    elif method == 'account/read':
        result(request, {'account': {'type': 'chatgpt', 'email': 'fixture@example.invalid'}})
    elif method == 'config/read':
        names=['shell_tool','unified_exec','code_mode','code_mode_host','apps','plugins','browser_use','computer_use','view_image','image_generation','multi_agent','hooks','workspace_dependencies','skill_search','skill_mcp_dependency_install','memories','chronicle']
        result(request, {'config': {'features':dict.fromkeys(names,False),'web_search':'disabled','mcp_servers':{}}})
    elif method == 'model/list':
        result(request, {'data': [{'model': 'fixture-model', 'isDefault': True}]})
    elif method == 'mcpServerStatus/list':
        result(request, {'data': [], 'nextCursor': None})
    elif method == 'thread/start':
        assert request['params']['ephemeral'] is True
        assert request['params']['approvalPolicy'] == 'never'
        result(request, {'thread': {'id': 'fixture-thread'}})
    elif method == 'turn/start':
        assert request['params']['sandboxPolicy'] == {'type': 'readOnly', 'networkAccess': False}
        text = request['params']['input'][0]['text']; last_text=text
        result(request, {'turn': {'id': 'fixture-turn', 'status': 'inProgress'}})
        emit({'method': 'turn/started', 'params': {'threadId': 'fixture-thread', 'turn': {'id': 'fixture-turn'}}})
        if text in ['CANCEL','CANCEL_RACE']:
            continue
        if text == 'FAIL':
            emit({'method': 'turn/completed', 'params': {'threadId': 'fixture-thread', 'turn': {'id': 'fixture-turn', 'status': 'failed', 'error': {'message': 'fixture failure'}}}})
        else:
            emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'fixture-thread', 'delta': '기록에서 '}})
            emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'fixture-thread', 'delta': '찾은 생각'}})
            emit({'method': 'turn/completed', 'params': {'threadId': 'fixture-thread', 'turn': {'id': 'fixture-turn', 'status': 'completed'}}})
    elif method == 'turn/interrupt':
        result(request, {})
        if last_text=='CANCEL_RACE':emit({'method':'item/agentMessage/delta','params':{'threadId':'fixture-thread','delta':'late answer'}})
        emit({'method': 'turn/completed', 'params': {'threadId': 'fixture-thread', 'turn': {'id': 'fixture-turn', 'status': 'completed' if last_text=='CANCEL_RACE' else 'interrupted'}}})
    else:
        emit({'id': request['id'], 'error': {'code': -32601, 'message': 'unknown fixture method'}})
