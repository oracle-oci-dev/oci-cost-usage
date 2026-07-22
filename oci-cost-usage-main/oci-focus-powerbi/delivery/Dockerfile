FROM fnproject/python:3.11-dev AS build

WORKDIR /function
COPY requirements.txt /function/
RUN pip3 install --no-cache-dir -r requirements.txt --target /python
COPY focus_to_sharepoint.py /function/focus_to_sharepoint.py

FROM fnproject/python:3.11
WORKDIR /function
COPY --from=build /python /python
COPY --from=build /function/focus_to_sharepoint.py /function/focus_to_sharepoint.py

ENTRYPOINT ["/python/bin/fdk", "/function/focus_to_sharepoint.py", "handler"]
