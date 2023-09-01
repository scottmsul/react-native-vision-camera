//
// Created by Marc Rousavy on 22.06.21.
//

#pragma once

#include <jsi/jsi.h>
#include <jni.h>
#include <fbjni/fbjni.h>

namespace vision {

namespace JSIJNIConversion {

using namespace facebook;

jni::local_ref<jni::JMap<jstring, jobject>> convertJSIObjectToJNIMap(jsi::Runtime& runtime, const jsi::Object& object);

jsi::Value convertJNIObjectToJSIValue(jsi::Runtime& runtime, const jni::local_ref<jobject>& object);

} // namespace JSIJNIConversion

} // namespace vision