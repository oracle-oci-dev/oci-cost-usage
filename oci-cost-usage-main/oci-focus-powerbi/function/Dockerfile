FROM fnproject/python:3.11-dev AS build

WORKDIR /function
COPY requirements.txt /function/
RUN pip3 install --no-cache-dir -r requirements.txt --target /python
COPY func.py /function/func.py

FROM fnproject/python:3.11
WORKDIR /function
COPY --from=build /python /python
COPY --from=build /function/func.py /function/func.py

ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
