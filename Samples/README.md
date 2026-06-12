# DroidShim Samples

This directory contains sample inputs and debugging aids for Phase 1.

## Hello World (text layout fallback)

Because Phase 1 cannot decode binary Android layout XML to UIKit, you can test
the runtime by manually extracting an APK and replacing `res/layout/main.xml`
with a simple text XML file inside the container directory:

```xml
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:padding="16dp">

    <TextView
        android:id="@+id/hello_text"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="Hello DroidShim!"
        android:textSize="24sp" />

    <Button
        android:id="@+id/hello_button"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="Tap me"
        android:onClick="onHelloClick" />
</LinearLayout>
```

Place this file at:

```
Documents/Containers/<package>/res/layout/main.xml
```

Then tap the container in DroidShimApp. The `onHelloClick` handler is resolved
through `JNIRegistry` from the converted native library (if the APK has one) or
stubbed for a Java-only APK.

## Building a real test APK

Use Android Studio to create a minimal Java-only app with a single Activity:

```java
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.main);
    }

    public void onHelloClick(View view) {
        TextView tv = findViewById(R.id.hello_text);
        tv.setText("Clicked!");
    }
}
```

Build an unsigned APK, sideload it through DroidShimApp, and verify that:
1. `APKParser` extracts the manifest, DEX, and resources.
2. `ARTInterpreter` runs `onCreate`.
3. `ViewMapper` builds the UIKit hierarchy.
4. The button tap calls `onHelloClick` and updates the label.

## Phase 2

In Phase 2 the text-layout fallback will be replaced by a real binary XML
layout decoder, so manual XML placement will no longer be required.
