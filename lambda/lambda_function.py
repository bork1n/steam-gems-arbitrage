import urllib2
import time
import socket
import json
import zlib, base64

def lambda_handler(event, context):
    #return event
    params = event["headers"]
    url = params["X-Query"]
    request = urllib2.Request(url)
    request.add_header('User-Agent', params["X-UA"])
    opener = urllib2.build_opener() 
    #jsonData = json.loads(opener.open(request).read())
    body = opener.open(request).read()
    
    return {
    "isBase64Encoded": False,
    "statusCode": 200,
    "headers": {
      "content-type": "application/json"  
    },
    "body": body
}


