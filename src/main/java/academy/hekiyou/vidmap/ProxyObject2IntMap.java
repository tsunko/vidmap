package academy.hekiyou.vidmap;

import it.unimi.dsi.fastutil.ints.IntCollection;
import it.unimi.dsi.fastutil.objects.Object2IntMap;
import it.unimi.dsi.fastutil.objects.Object2IntOpenHashMap;
import it.unimi.dsi.fastutil.objects.ObjectSet;
import org.jetbrains.annotations.NotNull;

import java.util.Map;

public class ProxyObject2IntMap<K> implements Object2IntMap<K> {

    private final Object2IntMap<K> delegate;
    private final Object2IntMap<K> proxy = new Object2IntOpenHashMap<>();

    public ProxyObject2IntMap(Object2IntMap<K> delegate){
        this.delegate = delegate;
    }

    public void putProxy(K key, int val){
        proxy.put(key, val);
    }

    @Override
    public int size() {
        return delegate.size();
    }

    @Override
    public boolean isEmpty() {
        return delegate.isEmpty();
    }

    @Override
    public void defaultReturnValue(int i) {
        delegate.defaultReturnValue(i);
    }

    @Override
    public int defaultReturnValue() {
        return delegate.defaultReturnValue();
    }

    @Override
    public ObjectSet<Entry<K>> object2IntEntrySet() {
        return delegate.object2IntEntrySet();
    }

    @Override
    public ObjectSet<K> keySet() {
        return delegate.keySet();
    }

    @Override
    public IntCollection values() {
        return delegate.values();
    }

    @Override
    public boolean containsKey(Object o) {
        return delegate.containsKey(o);
    }

    @Override
    public void putAll(@NotNull Map<? extends K, ? extends Integer> m) {
        delegate.putAll(m);
    }

    @Override
    public boolean containsValue(int i) {
        return delegate.containsValue(i);
    }

    @Override
    public int put(K key, int value) {
        return delegate.put(key, value);
    }

    @Override
    public int getInt(Object o) {
        if(proxy.containsKey(o)){
            return proxy.getInt(o);
        }
        return delegate.getInt(o);
    }

}
