# splunk-otel-collector


## Data Flow in the OpenTelemetry Collector
  - OpenTelemetry Collector: The process that collects data and exports it to the Splunk.
  - it handles collection of system metrics, traces, and logs.
  - To learn more about the OpenTelemetry Collector in general, read the Official documentation linked here https://opentelemetry.io/docs/collector/
**Pipelines Direct the Data Flow** : Pipelines are a central concept of the OpenTelemetry Collector.
  - There are currently exactly three types of pipeline: `Metric Pipelines`, `Trace Pipelines`, and `Log Pipelines`
  - A Pipeline is made of components. There are three types of components: **receivers**, **processors**, and **exporters**.
  - ![image](https://github.com/dyapas/splunk-otel-collector/assets/43857965/b4a84e31-c087-41ab-b64f-83ae73104362)
  - **Receiver**: Receivers fetch data and place it in the pipeline.  For example, a receiver might be a TCP listener, a system monitor, or a file reader.
  - **processors**: Once data is in the pipeline, a processor component filters, manipulates, or extends that data.
  - **exporters**: Exporters are used to send data out to another system, for example to the Splunk Observability Cloud.
  - Sample Pipeline:
    - ![image](https://github.com/dyapas/splunk-otel-collector/assets/43857965/f7ee3b3c-d21f-4b0d-b074-0ddaa84e4b33)
    - Pipelines are defined in the service block of the configuration file. The code above defines a `metrics pipeline`
    - **The Receivers Block**:
    - ![image](https://github.com/dyapas/splunk-otel-collector/assets/43857965/23190fcf-4f10-4b75-a007-876c27622752)
      - In above YAML, lines that begin with a hyphen indicate items in a "collection" (an ordered list). Under the word `receivers`, we see a collection containing four items. Each item is a previously-defined `receiver`. This pipeline has the `four receivers`
    - **The Processors Block**:
      - ![image](https://github.com/dyapas/splunk-otel-collector/assets/43857965/7a34c622-1121-4371-a18f-b5712da5fc43)
      - The line with the word `processors` is followed by a collection with `three items` in it. For the `processors` block, the **order matters**. A message will pass through each processor in **the order listed** in the config file.
    - **The Exporters**:
      -   ![image](https://github.com/dyapas/splunk-otel-collector/assets/43857965/f2832f00-75a7-4914-b9da-3e0ab2ff279e)
      -   In this metrics pipeline, there is only one `exporter`. If there were multiple `exporters`, every message would fan out to every `exporter`, and would be sent to every destination specified.
      -   If you don't want all messages to go to every exporter, you can define multiple pipelines with different `exporters`.





